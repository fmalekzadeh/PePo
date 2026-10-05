import Foundation

// MARK: - Requests

struct ChatMessage: Codable {
    let role: String
    /// Only plain string content is supported (not the multi-part `[{type, text}]`
    /// array form some clients can send). That covers every standard OpenAI chat
    /// client and keeps this server simple.
    let content: String
}

struct ChatCompletionRequest: Codable {
    var model: String?
    var messages: [ChatMessage]
    var temperature: Double?
    var max_tokens: Int?
    var stream: Bool?
    /// Non-standard, additive field: when present, the server keeps this named
    /// conversation alive itself (persisted to disk, auto-summarized near the
    /// context limit) instead of requiring the full history be resent every
    /// call. Only the newest message in `messages` is used when set. Omitting
    /// it keeps the default fully stateless, OpenAI-compatible behavior.
    var session: String?
}

// MARK: - Non-streaming response

struct ChatCompletionResponse: Codable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
    let usage: Usage

    struct Choice: Codable {
        let index: Int
        let message: ChatMessage
        let finish_reason: String
    }

    struct Usage: Codable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }

    static func make(content: String, model: String?, promptTokens: Int, completionTokens: Int) -> ChatCompletionResponse {
        ChatCompletionResponse(
            id: "chatcmpl-\(UUID().uuidString)",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: model ?? ModelCatalog.modelID,
            choices: [Choice(index: 0, message: ChatMessage(role: "assistant", content: content), finish_reason: "stop")],
            usage: Usage(prompt_tokens: promptTokens, completion_tokens: completionTokens, total_tokens: promptTokens + completionTokens)
        )
    }
}

// MARK: - Streaming response (SSE chunks)

struct ChatCompletionChunk: Codable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]

    struct Choice: Codable {
        let index: Int
        let delta: Delta
        let finish_reason: String?
    }

    struct Delta: Codable {
        var role: String?
        var content: String?
    }

    static func delta(_ text: String, model: String?, isFirst: Bool) -> ChatCompletionChunk {
        ChatCompletionChunk(
            id: "chatcmpl-\(UUID().uuidString)",
            object: "chat.completion.chunk",
            created: Int(Date().timeIntervalSince1970),
            model: model ?? ModelCatalog.modelID,
            choices: [Choice(index: 0, delta: Delta(role: isFirst ? "assistant" : nil, content: text), finish_reason: nil)]
        )
    }

    static func finish(model: String?) -> ChatCompletionChunk {
        ChatCompletionChunk(
            id: "chatcmpl-\(UUID().uuidString)",
            object: "chat.completion.chunk",
            created: Int(Date().timeIntervalSince1970),
            model: model ?? ModelCatalog.modelID,
            choices: [Choice(index: 0, delta: Delta(role: nil, content: nil), finish_reason: "stop")]
        )
    }
}

// MARK: - Models list

struct ModelCatalog {
    static let modelID = "apple-on-device"
}

struct ModelsListResponse: Codable {
    struct Model: Codable {
        let id: String
        let object: String
        let created: Int
        let owned_by: String
    }

    let object: String
    let data: [Model]

    static var current: ModelsListResponse {
        ModelsListResponse(
            object: "list",
            data: [Model(id: ModelCatalog.modelID, object: "model", created: 0, owned_by: "apple")]
        )
    }
}

// MARK: - Errors

struct OpenAIErrorResponse: Codable {
    struct ErrorBody: Codable {
        var message: String
        var type: String
        var param: String? = nil
        var code: String? = nil
    }

    var error: ErrorBody
}

// MARK: - Health

struct HealthResponse: Codable {
    let status: String
    let port: Int
    let model: String
}

// MARK: - Sessions (non-standard; this server's own named-session capability)

struct SessionsListResponse: Codable {
    struct Session: Codable {
        let name: String
        let tokens: Int
        let contextWindow: Int
    }

    let sessions: [Session]
}

struct ClearSessionRequest: Codable {
    let session: String
}

struct ClearSessionResponse: Codable {
    let cleared: Bool
    let session: String
}
