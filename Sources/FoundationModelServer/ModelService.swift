import Foundation
import FoundationModels

/// Thin wrapper around Apple's on-device `FoundationModels` framework.
///
/// Each request gets its own `LanguageModelSession`. For multi-turn requests
/// (an OpenAI-style `messages` array with more than one user/assistant turn),
/// prior history is replayed through FoundationModels' own `Transcript` type
/// rather than flattened into a hand-labeled text block. The flattened
/// approach measurably degrades response quality: e.g. asked plainly, the
/// model will state its training cutoff; the same question flattened into a
/// "User: ... / Assistant: ..." transcript with even one prior turn gets a
/// flat "I don't have a specific knowledge cutoff" with no date at all.
/// Rebuilding history as a native `Transcript` and calling `respond(to:)` for
/// only the newest turn avoids that regression.
struct ModelService {
    struct ChatResult {
        let content: String
        let promptTokens: Int
        let completionTokens: Int
        var totalTokens: Int { promptTokens + completionTokens }
    }

    enum ServiceError: Error, LocalizedError {
        case modelUnavailable(String)
        case emptyConversation
        case contextWindowExceeded(tokenCount: Int, limit: Int)

        var errorDescription: String? {
            switch self {
            case .modelUnavailable(let reason):
                return "Apple Intelligence model is unavailable: \(reason)"
            case .emptyConversation:
                return "'messages' must end with a user message to respond to."
            case .contextWindowExceeded(let tokenCount, let limit):
                return "This conversation (~\(tokenCount) tokens) exceeds the model's \(limit)-token context window. Trim earlier messages and try again."
            }
        }
    }

    /// The on-device model's real context window size, as reported by the
    /// framework itself (not a guess) — 4096 tokens as of this SDK, exposed via
    /// `SystemLanguageModel.contextSize` rather than hardcoded here.
    var contextWindowSize: Int {
        SystemLanguageModel.default.contextSize
    }

    /// Server-held named conversations (opt-in via `ChatCompletionRequest.session`).
    /// A reference type held by this otherwise-stateless struct on purpose: one
    /// `ModelService` instance lives for the server's whole run (see
    /// `ServerController`), so the manager's in-memory sessions persist across
    /// requests exactly as intended.
    private let sessionManager: SessionManager

    init() {
        sessionManager = SessionManager(contextWindowSize: SystemLanguageModel.default.contextSize)
    }

    func availabilityDescription() -> String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Model ready"
        case .unavailable(.deviceNotEligible):
            return "Unavailable — this Mac doesn't support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Unavailable — turn on Apple Intelligence in System Settings"
        case .unavailable(.modelNotReady):
            return "Unavailable — model is still downloading"
        case .unavailable:
            return "Unavailable — unknown reason"
        }
    }

    var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    func listSessions() async -> [SessionManager.SessionInfo] {
        await sessionManager.listSessions()
    }

    func setAutoSummaryEnabled(_ enabled: Bool) async {
        await sessionManager.setAutoSummaryEnabled(enabled)
    }

    func chatCompletion(_ request: ChatCompletionRequest) async throws -> ChatResult {
        try requireAvailable()
        if let sessionName = request.session {
            return try await sessionChatCompletion(sessionName: sessionName, request: request)
        }
        let (session, lastPrompt) = try Self.makeSession(for: request.messages)
        let options = GenerationOptions(temperature: request.temperature, maximumResponseTokens: request.max_tokens)
        let promptTokens = await Self.estimateInputTokens(messages: request.messages)
        do {
            let response = try await session.respond(to: lastPrompt, options: options)
            let completionTokens = await Self.estimateOutputTokens(response.content)
            return ChatResult(content: response.content, promptTokens: promptTokens, completionTokens: completionTokens)
        } catch {
            throw Self.translateContextWindowError(error, promptTokens: promptTokens, limit: contextWindowSize)
        }
    }

    /// Streams incremental text deltas via `onDelta`, then calls `onFinish` with
    /// the request's estimated total token count once generation completes.
    func streamChatCompletion(
        _ request: ChatCompletionRequest,
        onDelta: @Sendable (String, Bool) async -> Void,
        onFinish: (Int) async -> Void
    ) async throws {
        try requireAvailable()
        if let sessionName = request.session {
            try await sessionStreamChatCompletion(sessionName: sessionName, request: request, onDelta: onDelta, onFinish: onFinish)
            return
        }
        let (session, lastPrompt) = try Self.makeSession(for: request.messages)
        let options = GenerationOptions(temperature: request.temperature, maximumResponseTokens: request.max_tokens)
        let promptTokens = await Self.estimateInputTokens(messages: request.messages)
        let stream = session.streamResponse(to: lastPrompt, options: options)

        var previous = ""
        var isFirstDelta = true
        do {
            for try await snapshot in stream {
                let full = snapshot.content
                guard full.count > previous.count else { continue }
                let delta: String
                if full.hasPrefix(previous) {
                    delta = String(full.dropFirst(previous.count))
                } else {
                    // The snapshot wasn't a simple extension of the previous one;
                    // fall back to sending the whole current text as this "delta".
                    delta = full
                }
                previous = full
                await onDelta(delta, isFirstDelta)
                isFirstDelta = false
            }
        } catch {
            throw Self.translateContextWindowError(error, promptTokens: promptTokens, limit: contextWindowSize)
        }
        let completionTokens = await Self.estimateOutputTokens(previous)
        await onFinish(promptTokens + completionTokens)
    }

    /// Session-mode path: only the newest message is sent to the model — prior
    /// history lives in `SessionManager`'s own persisted, growing transcript
    /// for this name, not in what the client includes in `messages`.
    private func sessionChatCompletion(sessionName: String, request: ChatCompletionRequest) async throws -> ChatResult {
        guard let last = request.messages.last, last.role != "system" else {
            throw ServiceError.emptyConversation
        }
        let systemText = Self.systemText(from: request.messages)
        let options = GenerationOptions(temperature: request.temperature, maximumResponseTokens: request.max_tokens)
        let promptTokens = await Self.estimateOutputTokens(last.content)
        do {
            let result = try await sessionManager.respond(
                sessionName: sessionName,
                systemText: systemText,
                userMessage: last.content,
                options: options
            )
            return ChatResult(content: result.content, promptTokens: result.promptTokens, completionTokens: result.completionTokens)
        } catch {
            throw Self.translateContextWindowError(error, promptTokens: promptTokens, limit: contextWindowSize)
        }
    }

    private func sessionStreamChatCompletion(
        sessionName: String,
        request: ChatCompletionRequest,
        onDelta: @Sendable (String, Bool) async -> Void,
        onFinish: (Int) async -> Void
    ) async throws {
        guard let last = request.messages.last, last.role != "system" else {
            throw ServiceError.emptyConversation
        }
        let systemText = Self.systemText(from: request.messages)
        let options = GenerationOptions(temperature: request.temperature, maximumResponseTokens: request.max_tokens)
        let promptTokens = await Self.estimateOutputTokens(last.content)
        do {
            let result = try await sessionManager.streamRespond(
                sessionName: sessionName,
                systemText: systemText,
                userMessage: last.content,
                options: options,
                onDelta: onDelta
            )
            await onFinish(result.promptTokens + result.completionTokens)
        } catch {
            throw Self.translateContextWindowError(error, promptTokens: promptTokens, limit: contextWindowSize)
        }
    }

    private static func systemText(from messages: [ChatMessage]) -> String? {
        let text = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    private func requireAvailable() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable:
            throw ServiceError.modelUnavailable(availabilityDescription())
        }
    }

    /// Replaces the framework's own context-overflow error with our clearer,
    /// user-facing message carrying real numbers.
    ///
    /// Confirmed by actually triggering an overflow and inspecting the error:
    /// the framework throws the *older*, pre-27.0 shape —
    /// `LanguageModelSession.GenerationError.exceededContextWindowSize` — whose
    /// only payload is a free-text debug sentence, e.g. "Content contains
    /// 11260 tokens, which exceeds the maximum allowed context size of 4096."
    /// The real token count is parsed out of that sentence (more accurate than
    /// our own pre-flight estimate, since it reflects the framework's own
    /// Transcript encoding overhead, not just raw message text). The newer
    /// `LanguageModelError.contextSizeExceeded` (macOS 27+), which carries
    /// structured fields instead, is also handled in case a future SDK throws
    /// that one instead for this same call.
    private static func translateContextWindowError(_ error: Error, promptTokens: Int, limit: Int) -> Error {
        if #available(macOS 27.0, *), let modelError = error as? LanguageModelError,
           case .contextSizeExceeded(let details) = modelError {
            return ServiceError.contextWindowExceeded(tokenCount: details.tokenCount, limit: details.contextSize)
        }
        if let generationError = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize(let context) = generationError {
            let tokenCount = Self.firstInt(in: context.debugDescription) ?? promptTokens
            return ServiceError.contextWindowExceeded(tokenCount: tokenCount, limit: limit)
        }
        return error
    }

    private static func firstInt(in text: String) -> Int? {
        var digits = ""
        for character in text {
            if character.isNumber {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return Int(digits)
    }

    /// Estimates token counts using the model's own tokenizer
    /// (`SystemLanguageModel.tokenCount(for:)`, available 26.4+) so the numbers
    /// reported — in the API's `usage` field, the menu bar gauge, and
    /// context-overflow error messages — reflect real tokenization rather than
    /// a word-count guess.
    private static func estimateInputTokens(messages: [ChatMessage]) async -> Int {
        guard #available(macOS 26.4, *) else { return 0 }
        let inputText = messages.map(\.content).joined(separator: "\n")
        return (try? await SystemLanguageModel.default.tokenCount(for: inputText)) ?? 0
    }

    private static func estimateOutputTokens(_ text: String) async -> Int {
        guard #available(macOS 26.4, *) else { return 0 }
        return (try? await SystemLanguageModel.default.tokenCount(for: text)) ?? 0
    }

    /// Builds a session whose transcript natively replays every message except
    /// the last, and returns that session along with the last (newest user)
    /// message to respond to.
    private static func makeSession(for messages: [ChatMessage]) throws -> (LanguageModelSession, String) {
        guard let last = messages.last, last.role != "system" else {
            throw ServiceError.emptyConversation
        }

        var entries: [Transcript.Entry] = []

        let systemText = messages
            .filter { $0.role == "system" }
            .map(\.content)
            .joined(separator: "\n\n")
        if !systemText.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: systemText))],
                toolDefinitions: []
            )))
        }

        let history = messages.dropLast().filter { $0.role != "system" }
        for message in history {
            let segment = Transcript.Segment.text(Transcript.TextSegment(content: message.content))
            if message.role == "assistant" {
                entries.append(.response(Transcript.Response(assetIDs: [], segments: [segment])))
            } else {
                entries.append(.prompt(Transcript.Prompt(segments: [segment])))
            }
        }

        let session = LanguageModelSession(model: .default, transcript: Transcript(entries: entries))
        return (session, last.content)
    }
}
