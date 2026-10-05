import Foundation

enum ServerStatus: Equatable {
    case stopped
    case starting
    case running
    case error(String)
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

    /// Called (on the main thread) whenever any of the above changes.
    var onChange: (() -> Void)?

    private var server: HTTPServer?
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
    static let defaultPort: UInt16 = 11535

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    init() {
        let saved = Self.defaults.integer(forKey: Self.portDefaultsKey)
        port = (saved > 0 && saved <= Int(UInt16.max)) ? UInt16(saved) : Self.defaultPort
        autoSummaryEnabled = Self.defaults.object(forKey: Self.autoSummaryDefaultsKey) as? Bool ?? true
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
        refreshAvailability()

        let currentPort = port
        let router = Router(
            modelService: modelService,
            port: currentPort,
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
        let newServer = HTTPServer(port: currentPort, handler: router.handle)
        do {
            try newServer.start()
            server = newServer
            status = .running
        } catch {
            server = nil
            status = .error(error.localizedDescription)
        }
    }

    func stop() {
        server?.stop()
        server = nil
        status = .stopped
        activeRequestCount = 0
    }

    /// Applies a new port, restarting the server if it was running.
    func applyPort(_ newPort: UInt16) {
        let wasRunning = isRunning
        if wasRunning { stop() }
        port = newPort
        if wasRunning { start() }
    }
}
