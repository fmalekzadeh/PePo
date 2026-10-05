import Foundation

/// A parsed incoming HTTP request.
struct HTTPRequest {
    let method: String
    let path: String
    /// Header names are stored lowercased.
    let headers: [String: String]
    let body: Data

    /// Convenience: decode the JSON body as `Bool` for the OpenAI `"stream"` field,
    /// without fully decoding the request type yet.
    var wantsStream: Bool {
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return false }
        return (object["stream"] as? Bool) ?? false
    }
}

/// A complete, buffered HTTP response (used for the non-streaming path).
struct HTTPResponse {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ value: some Encodable, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    static func text(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(string.utf8))
    }

    static func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }
}
