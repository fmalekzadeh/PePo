import Foundation

/// Routes parsed HTTP requests to the right handler. Kept separate from
/// `HTTPServer` so the networking plumbing has no knowledge of OpenAI's API shape.
final class Router: Sendable {
    private let modelService: ModelService
    private let port: UInt16
    private let onRequestHandled: @Sendable () -> Void
    private let onTokensUsed: @Sendable (Int) -> Void
    private let onRequestStarted: @Sendable () -> Void
    private let onRequestFinished: @Sendable () -> Void

    init(
        modelService: ModelService,
        port: UInt16,
        onRequestHandled: @escaping @Sendable () -> Void,
        onTokensUsed: @escaping @Sendable (Int) -> Void,
        onRequestStarted: @escaping @Sendable () -> Void,
        onRequestFinished: @escaping @Sendable () -> Void
    ) {
        self.modelService = modelService
        self.port = port
        self.onRequestHandled = onRequestHandled
        self.onTokensUsed = onTokensUsed
        self.onRequestStarted = onRequestStarted
        self.onRequestFinished = onRequestFinished
    }

    func handle(_ request: HTTPRequest, writer: HTTPResponseWriter) async {
        onRequestHandled()
        switch (request.method, request.path) {
        case ("GET", "/health"), ("GET", "/"):
            let response = HealthResponse(status: "ok", port: Int(port), model: modelService.availabilityDescription())
            await writer.respond(.json(response))

        case ("GET", "/v1/models"):
            await writer.respond(.json(ModelsListResponse.current))

        case ("GET", "/v1/sessions"):
            let infos = await modelService.listSessions()
            let response = SessionsListResponse(sessions: infos.map {
                .init(name: $0.name, tokens: $0.tokenCount, contextWindow: modelService.contextWindowSize)
            })
            await writer.respond(.json(response))

        case ("POST", "/v1/chat/completions"):
            await handleChatCompletions(request, writer: writer)

        default:
            let error = OpenAIErrorResponse(error: .init(message: "No route for \(request.method) \(request.path)", type: "invalid_request_error"))
            await writer.respond(.json(error, status: 404))
        }
    }

    private func handleChatCompletions(_ request: HTTPRequest, writer: HTTPResponseWriter) async {
        onRequestStarted()
        defer { onRequestFinished() }

        let chatRequest: ChatCompletionRequest
        do {
            chatRequest = try JSONDecoder().decode(ChatCompletionRequest.self, from: request.body)
        } catch {
            let body = OpenAIErrorResponse(error: .init(message: "Could not parse request body: \(error.localizedDescription)", type: "invalid_request_error"))
            await writer.respond(.json(body, status: 400))
            return
        }
        guard !chatRequest.messages.isEmpty else {
            let body = OpenAIErrorResponse(error: .init(message: "'messages' must not be empty", type: "invalid_request_error"))
            await writer.respond(.json(body, status: 400))
            return
        }

        if chatRequest.stream == true {
            await streamChatCompletion(chatRequest, writer: writer)
        } else {
            do {
                let result = try await modelService.chatCompletion(chatRequest)
                onTokensUsed(result.totalTokens)
                await writer.respond(.json(ChatCompletionResponse.make(
                    content: result.content,
                    model: chatRequest.model,
                    promptTokens: result.promptTokens,
                    completionTokens: result.completionTokens
                )))
            } catch {
                await writer.respond(errorResponse(for: error))
            }
        }
    }

    private func errorResponse(for error: Error) -> HTTPResponse {
        if case ModelService.ServiceError.contextWindowExceeded = error {
            return .json(OpenAIErrorResponse(error: .init(message: error.localizedDescription, type: "invalid_request_error")), status: 400)
        }
        return .json(OpenAIErrorResponse(error: .init(message: error.localizedDescription, type: "server_error")), status: 503)
    }

    private func streamChatCompletion(_ chatRequest: ChatCompletionRequest, writer: HTTPResponseWriter) async {
        await writer.beginStream()
        do {
            try await modelService.streamChatCompletion(
                chatRequest,
                onDelta: { delta, isFirst in
                    let chunk = ChatCompletionChunk.delta(delta, model: chatRequest.model, isFirst: isFirst)
                    await send(chunk, via: writer)
                },
                onFinish: { totalTokens in
                    onTokensUsed(totalTokens)
                    await send(ChatCompletionChunk.finish(model: chatRequest.model), via: writer)
                    await writer.sendEvent("[DONE]")
                }
            )
        } catch {
            let body = OpenAIErrorResponse(error: .init(message: error.localizedDescription, type: "server_error"))
            if let data = try? JSONEncoder().encode(body), let json = String(data: data, encoding: .utf8) {
                await writer.sendEvent(json)
            }
            await writer.sendEvent("[DONE]")
        }
    }

    private func send(_ chunk: ChatCompletionChunk, via writer: HTTPResponseWriter) async {
        guard let data = try? JSONEncoder().encode(chunk), let json = String(data: data, encoding: .utf8) else { return }
        await writer.sendEvent(json)
    }
}
