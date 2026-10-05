import Foundation
import FoundationModels

/// Owns named, server-held conversations — an opt-in alternative to the
/// default stateless mode (where the client resends full history every call).
/// A client that passes `"session": "<name>"` only needs to send its newest
/// message each time; this actor keeps the real `LanguageModelSession` alive
/// between requests and persists its `Transcript` to disk after every turn.
///
/// Near the context window limit, instead of failing outright, a session is
/// automatically summarized (via one extra `respond()` call asking the model
/// to recap itself) and reset to a fresh, much shorter transcript seeded with
/// that summary — so the conversation keeps going. The full pre-summary
/// transcript is archived to disk first, so nothing is ever actually lost.
actor SessionManager {
    struct TurnResult {
        let content: String
        let promptTokens: Int
        let completionTokens: Int
    }

    struct SessionInfo {
        let name: String
        let tokenCount: Int
    }

    private struct State {
        var session: LanguageModelSession
        var cumulativeTokens: Int
        var systemText: String?
    }

    private var states: [String: State] = [:]
    private let contextWindowSize: Int
    private let storageDirectory: URL
    private var autoSummaryEnabled = true

    func setAutoSummaryEnabled(_ enabled: Bool) {
        autoSummaryEnabled = enabled
    }

    /// Summarize-and-reset triggers once a session's running total crosses
    /// this fraction of the context window — matched to the same 85% "red"
    /// threshold used by the menu bar icon, so a session resets itself before
    /// ever actually hitting the hard limit.
    private static let summarizeThreshold = 0.85

    init(contextWindowSize: Int) {
        self.contextWindowSize = contextWindowSize
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        storageDirectory = appSupport.appendingPathComponent("FoundationModelServer/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
    }

    func respond(sessionName: String, systemText: String?, userMessage: String, options: GenerationOptions) async throws -> TurnResult {
        var state = try await loadOrCreateState(name: sessionName, systemText: systemText)
        state = try await summarizeIfNeeded(name: sessionName, state: state)

        let promptTokens = await Self.tokenCount(for: userMessage)
        let response = try await state.session.respond(to: userMessage, options: options)
        let completionTokens = await Self.tokenCount(for: response.content)

        state.cumulativeTokens += promptTokens + completionTokens
        states[sessionName] = state
        persist(name: sessionName, transcript: state.session.transcript)

        return TurnResult(content: response.content, promptTokens: promptTokens, completionTokens: completionTokens)
    }

    func streamRespond(
        sessionName: String,
        systemText: String?,
        userMessage: String,
        options: GenerationOptions,
        onDelta: @Sendable (String, Bool) async -> Void
    ) async throws -> TurnResult {
        var state = try await loadOrCreateState(name: sessionName, systemText: systemText)
        state = try await summarizeIfNeeded(name: sessionName, state: state)

        let promptTokens = await Self.tokenCount(for: userMessage)
        let stream = state.session.streamResponse(to: userMessage, options: options)

        var previous = ""
        var isFirstDelta = true
        for try await snapshot in stream {
            let full = snapshot.content
            guard full.count > previous.count else { continue }
            let delta = full.hasPrefix(previous) ? String(full.dropFirst(previous.count)) : full
            previous = full
            await onDelta(delta, isFirstDelta)
            isFirstDelta = false
        }
        let completionTokens = await Self.tokenCount(for: previous)

        state.cumulativeTokens += promptTokens + completionTokens
        states[sessionName] = state
        persist(name: sessionName, transcript: state.session.transcript)

        return TurnResult(content: previous, promptTokens: promptTokens, completionTokens: completionTokens)
    }

    func listSessions() -> [SessionInfo] {
        states.map { SessionInfo(name: $0.key, tokenCount: $0.value.cumulativeTokens) }
            .sorted { $0.name < $1.name }
    }

    // MARK: - State loading

    private func loadOrCreateState(name: String, systemText: String?) async throws -> State {
        if let existing = states[name] {
            return existing
        }
        if let onDisk = loadFromDisk(name: name) {
            let session = LanguageModelSession(model: .default, transcript: onDisk)
            let tokens = await Self.tokenCount(for: Self.extractText(from: onDisk))
            let state = State(session: session, cumulativeTokens: tokens, systemText: systemText)
            states[name] = state
            return state
        }
        let session = LanguageModelSession(model: .default, instructions: systemText)
        let tokens = await Self.tokenCount(for: systemText ?? "")
        let state = State(session: session, cumulativeTokens: tokens, systemText: systemText)
        states[name] = state
        return state
    }

    // MARK: - Auto-summarize

    private func summarizeIfNeeded(name: String, state: State) async throws -> State {
        guard autoSummaryEnabled else { return state }
        let threshold = Int(Double(contextWindowSize) * Self.summarizeThreshold)
        guard state.cumulativeTokens >= threshold else { return state }

        // The full conversation is never discarded — it's archived to disk
        // exactly as it was the moment the threshold was crossed.
        archive(name: name, transcript: state.session.transcript)

        let summaryPrompt = "Summarize our conversation so far in a few concise sentences, preserving the important facts and context."
        let summaryResponse = try await state.session.respond(to: summaryPrompt)

        var entries: [Transcript.Entry] = []
        if let systemText = state.systemText, !systemText.isEmpty {
            entries.append(.instructions(Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: systemText))],
                toolDefinitions: []
            )))
        }
        entries.append(.prompt(Transcript.Prompt(
            segments: [.text(Transcript.TextSegment(content: "Here is a summary of our conversation so far:"))]
        )))
        entries.append(.response(Transcript.Response(
            assetIDs: [],
            segments: [.text(Transcript.TextSegment(content: summaryResponse.content))]
        )))
        let freshTranscript = Transcript(entries: entries)

        let newSession = LanguageModelSession(model: .default, transcript: freshTranscript)
        let newTokens = await Self.tokenCount(for: Self.extractText(from: freshTranscript))
        let newState = State(session: newSession, cumulativeTokens: newTokens, systemText: state.systemText)
        states[name] = newState
        persist(name: name, transcript: freshTranscript)
        return newState
    }

    // MARK: - Token estimation

    private static func tokenCount(for text: String) async -> Int {
        guard !text.isEmpty, #available(macOS 26.4, *) else { return 0 }
        return (try? await SystemLanguageModel.default.tokenCount(for: text)) ?? 0
    }

    private static func extractText(from transcript: Transcript) -> String {
        var parts: [String] = []
        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                parts.append(contentsOf: textSegments(instructions.segments))
            case .prompt(let prompt):
                parts.append(contentsOf: textSegments(prompt.segments))
            case .response(let response):
                parts.append(contentsOf: textSegments(response.segments))
            default:
                break
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func textSegments(_ segments: [Transcript.Segment]) -> [String] {
        segments.compactMap { segment in
            if case .text(let textSegment) = segment { return textSegment.content }
            return nil
        }
    }

    // MARK: - Disk persistence

    private func persist(name: String, transcript: Transcript) {
        guard let data = try? JSONEncoder().encode(transcript) else { return }
        try? data.write(to: fileURL(for: name))
    }

    private func archive(name: String, transcript: Transcript) {
        guard let data = try? JSONEncoder().encode(transcript) else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = storageDirectory.appendingPathComponent("\(Self.sanitize(name))_archive_\(timestamp).json")
        try? data.write(to: url)
    }

    private func loadFromDisk(name: String) -> Transcript? {
        guard let data = try? Data(contentsOf: fileURL(for: name)) else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    private func fileURL(for name: String) -> URL {
        storageDirectory.appendingPathComponent("\(Self.sanitize(name)).json")
    }

    /// Session names come from client input and become filenames — strip
    /// anything that isn't alphanumeric/dash/underscore so a crafted name like
    /// `"../../etc/passwd"` can't escape the sessions directory.
    private static func sanitize(_ name: String) -> String {
        let cleaned = name.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" }
        let result = String(cleaned)
        return result.isEmpty ? "default" : result
    }
}
