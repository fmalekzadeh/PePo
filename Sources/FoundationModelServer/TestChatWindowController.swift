import AppKit

/// A tiny, self-contained chat window for exercising the server without
/// needing an external client — talks to the server's own
/// `/v1/chat/completions` endpoint over loopback, the exact same way any
/// other client would, under the app's shared session name so multi-turn
/// context actually carries across messages. Persona (the instruction
/// prompt) and starting a new session both live in the main popover, not
/// here — this window just inherits whatever's currently set there.
@MainActor
final class TestChatWindowController: NSWindowController {
    private let controller: ServerController
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let inputField = NSTextField()
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)

    /// Tracks `controller.sessionGeneration` so that if "New Session" was
    /// used in the popover while this window wasn't frontmost, the stale
    /// transcript gets cleared the next time this window is actually shown,
    /// rather than silently disagreeing with what the server now holds.
    private var lastSeenGeneration: Int

    init(controller: ServerController) {
        self.controller = controller
        self.lastSeenGeneration = controller.sessionGeneration
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Test Chat"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 280, height: 260)
        window.center()
        super.init(window: window)
        window.contentViewController = makeContentViewController()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        if controller.sessionGeneration != lastSeenGeneration {
            lastSeenGeneration = controller.sessionGeneration
            textView.string = ""
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(inputField)
    }

    private func makeContentViewController() -> NSViewController {
        let viewController = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 420))

        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = "Type a message below to try the server.\n\n"
        scrollView.documentView = textView

        inputField.placeholderString = "Message…"
        inputField.target = self
        inputField.action = #selector(sendTapped)
        inputField.translatesAutoresizingMaskIntoConstraints = false

        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        container.addSubview(inputField)
        container.addSubview(sendButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: inputField.topAnchor, constant: -10),

            inputField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            inputField.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            inputField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -8),
            inputField.heightAnchor.constraint(equalToConstant: 22),

            sendButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            sendButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            sendButton.widthAnchor.constraint(equalToConstant: 60),
        ])

        viewController.view = container
        return viewController
    }

    @objc private func sendTapped() {
        let text = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputField.stringValue = ""
        appendMessage(name: "You", text: text, isUser: true)

        guard controller.isRunning else {
            appendSystemNote("⚠️ Server is stopped — turn it on from the popover first.")
            return
        }

        let port = controller.port
        let instructions = controller.sessionInstructions
        Task {
            do {
                let reply = try await Self.sendMessage(text, port: port, session: ServerController.appSessionName, instructions: instructions)
                appendMessage(name: "PePo", text: reply, isUser: false)
            } catch {
                appendSystemNote("⚠️ \(error.localizedDescription)")
            }
        }
    }

    /// Renders one chat turn like a familiar messaging UI: the user's own
    /// messages right-aligned in the accent color, the model's replies
    /// left-aligned in the normal text color, with the speaker name bolded
    /// above each — so a transcript with several back-and-forth turns stays
    /// easy to scan at a glance.
    private func appendMessage(name: String, text: String, isUser: Bool) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = isUser ? .right : .left

        let message = NSMutableAttributedString()
        message.append(NSAttributedString(string: "\(name)\n", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ]))
        message.append(NSAttributedString(string: "\(text)\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: isUser ? NSColor.controlAccentColor : NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ]))

        textView.textStorage?.append(message)
        textView.scrollToEndOfDocument(nil)
    }

    private func appendSystemNote(_ text: String) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let note = NSAttributedString(string: "\(text)\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle,
        ])
        textView.textStorage?.append(note)
        textView.scrollToEndOfDocument(nil)
    }

    /// `instructions`, if non-empty, is sent as a `"system"` role message
    /// alongside the user's own. The server only actually applies it the
    /// moment a named session is first created — on every later turn it's
    /// silently ignored — so it's safe (and simplest) to just always include
    /// whatever the popover's instruction prompt currently holds with every
    /// request, rather than tracking "is this the first message" here too.
    private static func sendMessage(_ text: String, port: UInt16, session: String, instructions: String) async throws -> String {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var messages: [[String: String]] = []
        if !instructions.isEmpty {
            messages.append(["role": "system", "content": instructions])
        }
        messages.append(["role": "user", "content": text])
        let body: [String: Any] = [
            "session": session,
            "messages": messages,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let errorJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let errorObject = errorJSON["error"] as? [String: Any],
               let message = errorObject["message"] as? String {
                throw TestChatError.server(message)
            }
            throw TestChatError.server("Request failed.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TestChatError.server("Unexpected response from the server.")
        }
        return content
    }
}

private enum TestChatError: LocalizedError {
    case server(String)

    var errorDescription: String? {
        switch self {
        case .server(let message): return message
        }
    }
}
