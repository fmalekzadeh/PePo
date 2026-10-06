import Foundation
import Security

enum ServerStatus: Equatable {
    case stopped
    case starting
    case running
    case error(String)
}

enum URLScheme: String {
    case http
    case https
}

/// Owns the HTTP server's lifecycle and the small bits of state the menu bar UI
/// shows: status, port (persisted across launches), and a running request count.
///
/// Plain AppKit-friendly class (no Combine/SwiftUI) — call `onChange` to find out
/// when the UI should refresh. Main-actor isolated since every mutation is
/// driven by UI actions or needs to land back on the main thread for the UI.
@MainActor
final class ServerController {
    private(set) var status: ServerStatus = .stopped {
        didSet { if status != oldValue { onChange?() } }
    }

    var port: UInt16 {
        didSet {
            guard port != oldValue else { return }
            Self.defaults.set(Int(port), forKey: Self.portDefaultsKey)
            onChange?()
        }
    }

    private(set) var requestCount: Int = 0 {
        didSet { onChange?() }
    }

    /// Total tokens (prompt + completion) used by the most recently completed
    /// chat request. Since every HTTP request rebuilds its own session from the
    /// client's full message history (no server-side persistent conversation),
    /// this — not a lifetime sum — is what actually tracks proximity to the
    /// model's context window for whatever conversation is currently live.
    private(set) var lastRequestTokenCount: Int = 0 {
        didSet { onChange?() }
    }

    /// The on-device model's real context window size (tokens), read from the
    /// framework itself.
    var contextWindowSize: Int { modelService.contextWindowSize }

    /// 0 when nothing has been used yet; can exceed 1.0 if a request actually
    /// overflowed the window. Framework-agnostic on purpose — AppKit-specific
    /// code (icon/label coloring) maps this to a color itself.
    var tokenUsageRatio: Double {
        guard contextWindowSize > 0 else { return 0 }
        return Double(lastRequestTokenCount) / Double(contextWindowSize)
    }

    private(set) var modelAvailabilityDescription: String = "Checking…" {
        didSet { onChange?() }
    }

    /// Whether named sessions auto-summarize themselves near the context
    /// window limit (see `SessionManager`). Off means a session that grows
    /// past the limit just fails with a clear error instead — no "magic"
    /// continuation, if that's not wanted.
    var autoSummaryEnabled: Bool {
        didSet {
            guard autoSummaryEnabled != oldValue else { return }
            Self.defaults.set(autoSummaryEnabled, forKey: Self.autoSummaryDefaultsKey)
            Task { await modelService.setAutoSummaryEnabled(autoSummaryEnabled) }
            onChange?()
        }
    }

    /// How many requests are currently being handled. Drives the menu bar
    /// icon's "busy" pulse — `onChange` only fires when this crosses the
    /// zero/non-zero boundary (becoming busy or going idle), not on every
    /// increment, since the icon only cares about busy-vs-not.
    private(set) var activeRequestCount: Int = 0 {
        didSet {
            if (activeRequestCount == 0) != (oldValue == 0) { onChange?() }
        }
    }

    var isBusy: Bool { activeRequestCount > 0 }

    /// The HTTPS listener's own port — separately configurable and persisted,
    /// defaulting to `port + 1` the first time.
    var httpsPort: UInt16 {
        didSet {
            guard httpsPort != oldValue else { return }
            Self.defaults.set(Int(httpsPort), forKey: Self.httpsPortDefaultsKey)
            onChange?()
        }
    }

    /// The port belonging to whichever scheme the popover is showing — what
    /// its Port field displays and edits.
    var displayedPort: UInt16 {
        displayedScheme == .https ? httpsPort : port
    }

    /// Whether the HTTPS listener actually started. Best-effort and
    /// independent of `status`/`isRunning` — if certificate generation or
    /// import fails for any reason (no `openssl`, etc.), the plain HTTP
    /// listener still runs exactly as it always has; this just stays false.
    private(set) var isHTTPSActive = false {
        didSet { if isHTTPSActive != oldValue { onChange?() } }
    }

    /// Set when the HTTPS listener tried to start and couldn't — lets the
    /// popover tell "still loading the certificate" apart from "won't come up".
    private(set) var didHTTPSFail = false {
        didSet { if didHTTPSFail != oldValue { onChange?() } }
    }

    /// The certificate the HTTPS listener is serving, once it's loaded.
    private var tlsCertificate: SecCertificate?

    /// Whether this Mac's trust settings accept `tlsCertificate` for TLS.
    /// Browsers silently fail every `fetch()` to an untrusted certificate (a
    /// background request has no click-through warning page), so HTTPS is
    /// useless to a hosted page until this is true.
    private(set) var isCertificateTrusted = false {
        didSet { if isCertificateTrusted != oldValue { onChange?() } }
    }

    /// Set while the system password prompt for trusting the certificate is up.
    private(set) var isTrustingCertificate = false {
        didSet { if isTrustingCertificate != oldValue { onChange?() } }
    }

    /// Asks macOS (password prompt) to trust the HTTPS certificate in the
    /// user's login keychain — Safari and Chrome both read trust from there.
    /// Returns an error message to show, or `nil` on success/cancel.
    func trustCertificate() async -> String? {
        guard let tlsCertificate, !isTrustingCertificate else { return nil }
        isTrustingCertificate = true
        defer { isTrustingCertificate = false }
        do {
            try await TLSIdentityManager.trust(tlsCertificate)
        } catch {
            refreshCertificateTrust()
            return error.localizedDescription
        }
        refreshCertificateTrust()
        return nil
    }

    func refreshCertificateTrust() {
        guard let tlsCertificate else {
            isCertificateTrusted = false
            return
        }
        isCertificateTrusted = TLSIdentityManager.isTrusted(tlsCertificate)
    }

    /// Which of the two (always both running) listeners the popover shows and
    /// copies the URL for. Purely a display choice — the server can't know
    /// which scheme a client will use, so the user picks the one they're
    /// about to paste somewhere. Persisted across launches.
    var displayedScheme: URLScheme {
        didSet {
            guard displayedScheme != oldValue else { return }
            Self.defaults.set(displayedScheme.rawValue, forKey: Self.schemeDefaultsKey)
            onChange?()
        }
    }

    /// The API base URL for `displayedScheme`, or `nil` when HTTPS is picked
    /// but its listener didn't come up.
    var displayedBaseURL: String? {
        switch displayedScheme {
        case .http:
            return "http://127.0.0.1:\(port)/v1"
        case .https:
            guard isHTTPSActive else { return nil }
            return "https://127.0.0.1:\(httpsPort)/v1"
        }
    }

    /// System instructions sent once, when a session is first created — set
    /// from the main popover, inherited by Test Chat (and any other client
    /// that uses the shared `appSessionName` session). Persisted so it
    /// survives a popover close/reopen and an app restart.
    var sessionInstructions: String {
        didSet {
            guard sessionInstructions != oldValue else { return }
            Self.defaults.set(sessionInstructions, forKey: Self.instructionsDefaultsKey)
        }
    }

    /// Bumped every time `startNewSession()` runs, so any other UI showing
    /// this session's transcript (Test Chat) can tell its displayed history
    /// just went stale without needing a full observer/notification system.
    private(set) var sessionGeneration = 0

    /// Whether the app's shared session actually exists yet — checked
    /// against `SessionManager` itself (not inferred/assumed here), since an
    /// external client can create or use it just as validly as Test Chat
    /// can. Drives graying out the instruction prompt once editing it would
    /// silently have no effect. Call `refreshAppSessionActiveState()` to
    /// requery; this just reflects the last known answer.
    private(set) var isAppSessionActive = false {
        didSet { if isAppSessionActive != oldValue { onChange?() } }
    }

    /// The single named, server-held session the app's own UI (Test Chat)
    /// talks to — distinct from arbitrary session names an external client
    /// might use. A shared constant so the popover's "New Session" action and
    /// Test Chat's requests can never drift onto different session names.
    static let appSessionName = "default"

    static let defaultInstructions = "You are a friendly, helpful assistant. Keep your answers clear and concise."

    /// Ends the app's own session so its next message starts fresh under
    /// whatever's currently in `sessionInstructions` — the only way to change
    /// persona mid-conversation, since instructions only take effect when a
    /// session is first created.
    func startNewSession() {
        sessionGeneration += 1
        isAppSessionActive = false
        sessionInstructions = Self.defaultInstructions
        Task { await modelService.clearSession(Self.appSessionName) }
    }

    /// Re-checks whether the app's shared session actually exists right now.
    /// Cheap (an in-process actor call) — safe to call on every popover
    /// refresh so a change made elsewhere (Test Chat, or any external
    /// client) is reflected the next time the popover is opened.
    func refreshAppSessionActiveState() {
        Task {
            isAppSessionActive = await modelService.isSessionActive(Self.appSessionName)
        }
    }

    /// Called (on the main thread) whenever any of the above changes.
    var onChange: (() -> Void)?

    private var server: HTTPServer?
    private var httpsServer: HTTPServer?
    private let modelService = ModelService()

    // Deliberately distinct from the app's own CFBundleIdentifier
    // ("com.local.FoundationModelServer"): macOS treats a suite name equal to
    // your own bundle ID as "nonsensical" and silently no-ops it. Using our own
    // suite also keeps this working when run as a bare binary outside the .app
    // bundle (no bundle identifier at all), where `.standard` would otherwise
    // fall back to a fragile process-name-keyed domain.
    private static let defaults = UserDefaults(suiteName: "com.local.FoundationModelServer.prefs")!
    private static let portDefaultsKey = "port"
    private static let autoSummaryDefaultsKey = "autoSummaryEnabled"
    private static let instructionsDefaultsKey = "sessionInstructions"
    private static let schemeDefaultsKey = "displayedScheme"
    private static let httpsPortDefaultsKey = "httpsPort"
    static let defaultPort: UInt16 = 11535

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    init() {
        let saved = Self.defaults.integer(forKey: Self.portDefaultsKey)
        port = (saved > 0 && saved <= Int(UInt16.max)) ? UInt16(saved) : Self.defaultPort
        let savedHTTPS = Self.defaults.integer(forKey: Self.httpsPortDefaultsKey)
        if savedHTTPS > 0 && savedHTTPS <= Int(UInt16.max) {
            httpsPort = UInt16(savedHTTPS)
        } else {
            httpsPort = port == UInt16.max ? port - 1 : port + 1
        }
        autoSummaryEnabled = Self.defaults.object(forKey: Self.autoSummaryDefaultsKey) as? Bool ?? true
        sessionInstructions = Self.defaults.string(forKey: Self.instructionsDefaultsKey) ?? Self.defaultInstructions
        displayedScheme = Self.defaults.string(forKey: Self.schemeDefaultsKey).flatMap(URLScheme.init(rawValue:)) ?? .http
        refreshAvailability()
        // The didSet above doesn't fire for this first assignment, so push
        // the loaded value through explicitly.
        let initialAutoSummary = autoSummaryEnabled
        Task { await modelService.setAutoSummaryEnabled(initialAutoSummary) }
    }

    func refreshAvailability() {
        modelAvailabilityDescription = modelService.availabilityDescription()
    }

    func start() {
        guard !isRunning else { return }
        status = .starting
        didHTTPSFail = false
        refreshAvailability()

        let currentPort = port
        let router = makeRouter(port: currentPort)
        let newServer = HTTPServer(port: currentPort, handler: router.handle)
        do {
            try newServer.start()
            server = newServer
            status = .running
        } catch {
            server = nil
            status = .error(error.localizedDescription)
            return
        }

        // Additive and best-effort: runs after the primary HTTP listener is
        // already confirmed up, and never affects `status` either way.
        let httpsRouter = makeRouter(port: httpsPort)
        let currentHTTPSPort = httpsPort
        Task { [weak self] in
            await self?.startHTTPSServer(router: httpsRouter, port: currentHTTPSPort)
        }
    }

    private func makeRouter(port: UInt16) -> Router {
        Router(
            modelService: modelService,
            port: port,
            onRequestHandled: { [weak self] in
                Task { @MainActor in
                    self?.requestCount += 1
                }
            },
            onTokensUsed: { [weak self] tokens in
                Task { @MainActor in
                    self?.lastRequestTokenCount = tokens
                }
            },
            onRequestStarted: { [weak self] in
                Task { @MainActor in
                    self?.activeRequestCount += 1
                }
            },
            onRequestFinished: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.activeRequestCount = max(0, self.activeRequestCount - 1)
                }
            }
        )
    }

    private func startHTTPSServer(router: Router, port: UInt16) async {
        do {
            let (identity, certificate) = try await TLSIdentityManager.loadOrCreateIdentity()
            guard isRunning else { return } // stopped while the cert was loading
            tlsCertificate = certificate
            refreshCertificateTrust()
            let newHTTPSServer = HTTPServer(port: port, tlsIdentity: identity, handler: router.handle)
            try newHTTPSServer.start()
            httpsServer = newHTTPSServer
            isHTTPSActive = true
        } catch {
            isHTTPSActive = false
            didHTTPSFail = true
        }
    }

    func stop() {
        server?.stop()
        server = nil
        httpsServer?.stop()
        httpsServer = nil
        isHTTPSActive = false
        status = .stopped
        activeRequestCount = 0
    }

    /// Applies a new port to the scheme the popover is showing, restarting
    /// the server if it was running. Returns false (nothing changed) if it
    /// would collide with the other scheme's port.
    @discardableResult
    func applyDisplayedPort(_ newPort: UInt16) -> Bool {
        let otherPort = displayedScheme == .https ? port : httpsPort
        guard newPort != otherPort else { return false }
        guard newPort != displayedPort else { return true }
        let wasRunning = isRunning
        if wasRunning { stop() }
        switch displayedScheme {
        case .http: port = newPort
        case .https: httpsPort = newPort
        }
        if wasRunning { start() }
        return true
    }
}
