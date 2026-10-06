import Foundation
import Security

/// Mints (once) and loads a self-signed TLS identity for `127.0.0.1`/`localhost`,
/// so the server can also serve HTTPS alongside its plain HTTP listener.
///
/// This exists because of a browser-specific gap: a page published on a public
/// HTTPS origin (e.g. a hosted Figma prototype) that calls back into a local
/// PePo instance on the same Mac hits two different browser restrictions.
/// Chrome's is Private Network Access, which the server can satisfy with a
/// response header (see `HTTPServer`'s `OPTIONS` handling). Safari's is plain
/// mixed-content blocking — WebKit refuses `fetch()`/XHR from an `https://`
/// page to any `http://` target, loopback included, with no response header
/// able to override it. The only fix is serving `https://127.0.0.1:<port>`
/// too, so the published page's own HTTPS scheme is preserved end to end.
///
/// The private key and certificate are generated once via the system's own
/// `/usr/bin/openssl` — present on stock macOS (confirmed via `pkgutil
/// --file-info`, which tracks it as a system-owned file, not something only
/// Xcode Command Line Tools installs) — and persisted as a PKCS#12 bundle in
/// Application Support, reused until it nears expiry. Importing it uses
/// `kSecImportToMemoryOnly`, so the private key never enters the keychain.
///
/// A self-signed certificate is useless to a browser until the Mac trusts it:
/// a page's background `fetch()` has no click-through warning, it just fails.
/// `trust(_:)` adds only the (public) certificate to the login keychain with
/// an SSL trust setting — Safari and Chrome both honor that. The certificate
/// itself also has to meet Apple's TLS server rules (≤ 825 days validity,
/// `serverAuth` extended key usage, SAN), or macOS rejects it even when
/// trusted.
enum TLSIdentityManager {
    enum IdentityError: Error, LocalizedError {
        case opensslUnavailable
        case opensslFailed(String)
        case importFailed(OSStatus)
        case noIdentityInResult
        case trustFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .opensslUnavailable:
                return "/usr/bin/openssl isn't available, so a local HTTPS certificate couldn't be generated."
            case .opensslFailed(let message):
                return "openssl failed: \(message)"
            case .importFailed(let status):
                return "Importing the generated certificate failed (status \(status))."
            case .noIdentityInResult:
                return "The generated certificate didn't contain a usable identity."
            case .trustFailed(let status):
                let reason = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Couldn't trust the certificate: \(reason)"
            }
        }
    }

    /// Only protects the PKCS#12 container format itself (required by the
    /// format, not a secret) — the file lives in this app's own Application
    /// Support directory under normal file permissions, same as everything
    /// else SessionManager persists there.
    private static let passphrase = "pepo-local-tls"

    /// Returns a usable `sec_identity_t`, generating and caching the
    /// certificate on first call if needed. Throws if `openssl` isn't present
    /// or generation/import otherwise fails — callers should treat that as
    /// "HTTPS isn't available this run," not a fatal error; the plain HTTP
    /// listener works regardless.
    static func loadOrCreateIdentity() async throws -> (sec_identity_t, SecCertificate) {
        let dir = try tlsDirectory()
        // v1 ("identity.p12") was valid for 10 years with no serverAuth EKU,
        // which macOS rejects outright — never reuse it.
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("identity.p12"))

        let p12URL = dir.appendingPathComponent("identity-v2.p12")
        if let existing = try? Data(contentsOf: p12URL), !existing.isEmpty,
           let loaded = try? importIdentity(from: existing),
           !expiresSoon(loaded.1) {
            return loaded
        }
        if let stale = (try? Data(contentsOf: p12URL)).flatMap({ try? importIdentity(from: $0) }) {
            untrust(stale.1)
        }
        let p12Data = try await generateP12()
        try p12Data.write(to: p12URL, options: .atomic)
        return try importIdentity(from: p12Data)
    }

    /// Whether this Mac currently accepts `certificate` as a TLS server
    /// certificate for 127.0.0.1 — the same evaluation Safari performs.
    static func isTrusted(_ certificate: SecCertificate) -> Bool {
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, "127.0.0.1" as CFString)
        guard SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess,
              let trust else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// Adds `certificate` to the login keychain and marks it trusted for SSL.
    /// macOS shows its own password prompt; cancelling throws.
    static func trust(_ certificate: SecCertificate) async throws {
        try await Task.detached {
            let addStatus = SecItemAdd([
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate,
            ] as CFDictionary, nil)
            guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
                throw IdentityError.trustFailed(addStatus)
            }
            let settings: [[String: Any]] = [[
                kSecTrustSettingsPolicy as String: SecPolicyCreateSSL(true, nil),
                kSecTrustSettingsResult as String: SecTrustSettingsResult.trustRoot.rawValue,
            ]]
            let status = SecTrustSettingsSetTrustSettings(certificate, .user, settings as CFArray)
            guard status == errSecSuccess else {
                throw IdentityError.trustFailed(status)
            }
        }.value
    }

    /// Best-effort cleanup when a certificate is being replaced, so expired
    /// PePo certificates don't pile up as trusted roots.
    private static func untrust(_ certificate: SecCertificate) {
        SecTrustSettingsRemoveTrustSettings(certificate, .user)
        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
        ] as CFDictionary)
    }

    /// Regenerate a month ahead of expiry rather than serving a dead cert.
    private static func expiresSoon(_ certificate: SecCertificate) -> Bool {
        guard let values = SecCertificateCopyValues(certificate, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [String: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let seconds = (entry[kSecPropertyKeyValue as String] as? NSNumber)?.doubleValue else {
            return true
        }
        let notAfter = Date(timeIntervalSinceReferenceDate: seconds)
        return notAfter.timeIntervalSinceNow < 30 * 24 * 60 * 60
    }

    private static func tlsDirectory() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent("FoundationModelServer/TLS", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func generateP12() async throws -> Data {
        let opensslPath = "/usr/bin/openssl"
        guard FileManager.default.isExecutableFile(atPath: opensslPath) else {
            throw IdentityError.opensslUnavailable
        }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let keyURL = tempDir.appendingPathComponent("key.pem")
        let certURL = tempDir.appendingPathComponent("cert.pem")
        let p12URL = tempDir.appendingPathComponent("identity.p12")

        try await runOpenSSL(opensslPath, [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyURL.path, "-out", certURL.path,
            // 825 days is Apple's maximum for a TLS server certificate.
            "-days", "825", "-nodes",
            "-subj", "/CN=Petit Pomme Local (127.0.0.1)",
            "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
            "-addext", "extendedKeyUsage=serverAuth",
            "-addext", "keyUsage=critical,digitalSignature,keyEncipherment",
            "-addext", "basicConstraints=critical,CA:FALSE",
        ])
        try await runOpenSSL(opensslPath, [
            "pkcs12", "-export",
            "-inkey", keyURL.path, "-in", certURL.path,
            "-out", p12URL.path,
            "-passout", "pass:\(passphrase)",
        ])
        return try Data(contentsOf: p12URL)
    }

    private static func runOpenSSL(_ path: String, _ arguments: [String]) async throws {
        let exitCode: Int32
        let errorText: String
        (exitCode, errorText) = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = Pipe()
            process.terminationHandler = { proc in
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: errorData, encoding: .utf8) ?? ""
                continuation.resume(returning: (proc.terminationStatus, text))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        guard exitCode == 0 else {
            throw IdentityError.opensslFailed(errorText.isEmpty ? "exit code \(exitCode)" : errorText)
        }
    }

    private static func importIdentity(from p12Data: Data) throws -> (sec_identity_t, SecCertificate) {
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase,
            kSecImportToMemoryOnly as String: true,
        ]
        var rawItems: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess, let items = rawItems as? [[String: Any]] else {
            throw IdentityError.importFailed(status)
        }
        guard let first = items.first,
              let secIdentityRef = first[kSecImportItemIdentity as String] else {
            throw IdentityError.noIdentityInResult
        }
        // swiftlint:disable:next force_cast — the documented value type for
        // this dictionary key is always SecIdentity.
        let secIdentity = secIdentityRef as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(secIdentity, &certificate) == errSecSuccess,
              let certificate,
              let identity = sec_identity_create(secIdentity) else {
            throw IdentityError.noIdentityInResult
        }
        return (identity, certificate)
    }
}
