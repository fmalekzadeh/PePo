import Foundation
import Network
import os.log

private let log = Logger(subsystem: "com.local.FoundationModelServer", category: "HTTPServer")

/// Writes one response to a single accepted connection.
///
/// Handlers call either `respond(_:)` once for a normal buffered response, or
/// `beginStream()` followed by any number of `sendEvent(_:)` calls for a
/// Server-Sent-Events style streaming response (used for OpenAI `"stream": true`
/// chat completions). Only the first call of either kind has any effect.
actor HTTPResponseWriter {
    private let connection: NWConnection
    private var started = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func respond(_ response: HTTPResponse) async {
        guard !started else { return }
        started = true
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        headers["Access-Control-Allow-Origin"] = "*"
        var data = Data(makeHeaderBlock(status: response.status, headers: headers).utf8)
        data.append(response.body)
        await sendRaw(data)
    }

    func beginStream() async {
        guard !started else { return }
        started = true
        let headers = [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "close",
            "Access-Control-Allow-Origin": "*",
        ]
        await sendRaw(Data(makeHeaderBlock(status: 200, headers: headers).utf8))
    }

    /// Sends one SSE event. Only valid after `beginStream()`.
    func sendEvent(_ payload: String) async {
        await sendRaw(Data("data: \(payload)\n\n".utf8))
    }

    private func makeHeaderBlock(status: Int, headers: [String: String]) -> String {
        var lines = ["HTTP/1.1 \(status) \(HTTPResponse.statusText(for: status))"]
        for (key, value) in headers {
            lines.append("\(key): \(value)")
        }
        lines.append("")
        lines.append("")
        return lines.joined(separator: "\r\n")
    }

    private func sendRaw(_ data: Data) async {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}

typealias HTTPHandler = (HTTPRequest, HTTPResponseWriter) async -> Void

/// A minimal, dependency-free HTTP/1.1 server built directly on Network.framework.
///
/// This is intentionally small: it understands just enough of HTTP/1.1 to serve a
/// local JSON API (request line, headers, `Content-Length` bodies) plus very basic
/// SSE-style streaming for chat completion responses. It does not support
/// keep-alive, chunked request bodies, or HTTP/2 — none of which are needed for a
/// localhost API server talking to a handful of clients.
// The only mutable state is `listener`, and it's only ever written/read from
// `start()`/`stop()`, both called exclusively from the main actor by
// `ServerController`. The background queue's connection/state closures below
// only touch the immutable `queue` and `handler` lets, so there's no actual
// data race despite the compiler not being able to see that.
final class HTTPServer: @unchecked Sendable {
    enum ServerError: Error, LocalizedError {
        case invalidPort
        case failedToStart(String)

        var errorDescription: String? {
            switch self {
            case .invalidPort: return "Invalid port number."
            case .failedToStart(let message): return message
            }
        }
    }

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.local.FoundationModelServer.httpserver")
    let port: UInt16
    private let handler: HTTPHandler

    init(port: UInt16, handler: @escaping HTTPHandler) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.invalidPort
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Localhost-only: restrict to the loopback interface so this never
        // listens on the network, not just the Wi-Fi/Ethernet interface.
        params.requiredInterfaceType = .loopback

        let newListener: NWListener
        do {
            newListener = try NWListener(using: params, on: nwPort)
        } catch {
            throw ServerError.failedToStart(error.localizedDescription)
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var startError: Error?
        newListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                startError = nil
                semaphore.signal()
            case .failed(let error), .waiting(let error):
                startError = error
                semaphore.signal()
            case .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        newListener.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 3)
        if let startError {
            newListener.cancel()
            throw ServerError.failedToStart(startError.localizedDescription)
        }
        listener = newListener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        Task {
            await Self.handleConnection(connection, handler: handler)
        }
    }

    private static func handleConnection(_ connection: NWConnection, handler: @escaping HTTPHandler) async {
        defer { connection.cancel() }
        do {
            guard let request = try await readRequest(from: connection) else { return }

            if request.method == "OPTIONS" {
                let writer = HTTPResponseWriter(connection: connection)
                var headers: [String: String] = [
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                    "Access-Control-Allow-Headers": "Content-Type, Authorization",
                ]
                headers["Content-Type"] = "text/plain"
                await writer.respond(HTTPResponse(status: 204, headers: headers))
                return
            }

            let writer = HTTPResponseWriter(connection: connection)
            await handler(request, writer)
        } catch {
            log.error("Connection error: \(String(describing: error))")
        }
    }

    // MARK: - Request parsing

    private static func receiveChunk(_ connection: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private static func readRequest(from connection: NWConnection) async throws -> HTTPRequest? {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?

        while headerEnd == nil {
            guard let chunk = try await receiveChunk(connection) else {
                return nil
            }
            if !chunk.isEmpty {
                buffer.append(chunk)
            }
            headerEnd = buffer.range(of: separator)
            if buffer.count > 4_000_000 {
                return nil // guard against pathological requests
            }
        }

        guard let headerEnd, let headerString = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            return nil
        }
        var bodyData = buffer[headerEnd.upperBound...]

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2)
        guard requestParts.count >= 2 else { return nil }
        let method = String(requestParts[0])
        let path = String(requestParts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        while bodyData.count < contentLength {
            guard let chunk = try await receiveChunk(connection) else { break }
            bodyData.append(chunk)
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: Data(bodyData.prefix(contentLength)))
    }
}
