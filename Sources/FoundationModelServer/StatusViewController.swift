import AppKit

private extension NSBox {
    static func separatorLine() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

/// The popover content, laid out like a native macOS control panel (think the
/// Wi-Fi menu-bar panel): a label + toggle at the top, a status message
/// beneath it, server details in the middle, and plain menu-style
/// Test/About/Quit rows at the bottom.
final class StatusViewController: NSViewController {
    private let controller: ServerController

    private let serverLabel = NSTextField(labelWithString: "Server")
    private let serverToggle = NSSwitch()
    /// Doubles as the token-usage readout while running ("Model ready ·
    /// 312/4096 tokens") — `modelAvailabilityDescription` rarely changes once
    /// Apple Intelligence is enabled, so this line would otherwise sit mostly
    /// static; token proximity to the limit is the more useful live thing to
    /// show here, and it's what actually changes per request.
    private let statusMessageLabel = NSTextField(wrappingLabelWithString: "")

    private let portField = NSTextField()
    private let urlLabel = NSTextField(labelWithString: "")
    private let copyURLButton = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy URL") ?? NSImage(), target: nil, action: nil)
    private let httpsNoteLabel = NSTextField(wrappingLabelWithString: "")
    private let endpointsLabel = NSTextField(wrappingLabelWithString: "")
    private let autoSummaryLabel = NSTextField(labelWithString: "Auto-summarize sessions")
    private let autoSummaryToggle = NSSwitch()
    private let autoSummaryNoteLabel = NSTextField(wrappingLabelWithString: "")
    private let requestCountLabel = NSTextField(labelWithString: "")

    private let instructionsLabel = NSTextField(labelWithString: "Instruction prompt (Optional)")
    private let instructionsEditButton = NSButton(image: NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit instruction prompt") ?? NSImage(), target: nil, action: nil)
    private let instructionsCancelButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel") ?? NSImage(), target: nil, action: nil)
    private let instructionsSaveButton = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save") ?? NSImage(), target: nil, action: nil)
    private let instructionsTextView = NSTextView()
    private let instructionsScrollView = NSScrollView()
    private let instructionsNoteLabel = NSTextField(wrappingLabelWithString: "")
    /// Whether the instruction box is currently in its editable state (entered
    /// via the pencil button) — greyed out and read-only the rest of the time,
    /// so there's never ambiguity about whether typing "did" anything.
    private var isEditingInstructions = false

    private let testRow = MenuRowView(title: "Test Chat", shortcut: "⌘T")
    private let newSessionRow = MenuRowView(title: "New Session", shortcut: "⌘N")
    private let aboutRow = MenuRowView(title: "About", shortcut: "⌘A")
    private let quitRow = MenuRowView(title: "Quit", shortcut: "⌘Q")
    /// Invisible — exist only so these have real keyboard shortcuts while the
    /// popover is key. `MenuRowView` is a plain view (not an `NSButton`), so
    /// it has no `keyEquivalent` of its own.
    private let testKeyEquivalentButton = NSButton(title: "", target: nil, action: nil)
    private let newSessionKeyEquivalentButton = NSButton(title: "", target: nil, action: nil)
    private let aboutKeyEquivalentButton = NSButton(title: "", target: nil, action: nil)
    private let quitKeyEquivalentButton = NSButton(title: "", target: nil, action: nil)
    private let aboutWindowController = AboutWindowController()
    private var testChatWindowController: TestChatWindowController?

    private let popoverWidth: CGFloat = 300
    private let popoverPadding: CGFloat = 18
    private var contentStack: NSStackView!

    init(controller: ServerController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let effectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: 10))
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        view = effectView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildLayout()

        portField.stringValue = String(controller.port)
        portField.target = self
        portField.action = #selector(portFieldChanged)

        serverToggle.target = self
        serverToggle.action = #selector(serverToggleChanged(_:))
        serverToggle.setAccessibilityLabel("Server")

        autoSummaryToggle.target = self
        autoSummaryToggle.action = #selector(autoSummaryToggleChanged(_:))
        autoSummaryToggle.setAccessibilityLabel("Auto-summarize sessions")

        copyURLButton.target = self
        copyURLButton.action = #selector(copyURLTapped)

        instructionsTextView.string = controller.sessionInstructions

        instructionsEditButton.target = self
        instructionsEditButton.action = #selector(instructionsEditTapped)
        instructionsCancelButton.target = self
        instructionsCancelButton.action = #selector(instructionsCancelTapped)
        instructionsSaveButton.target = self
        instructionsSaveButton.action = #selector(instructionsSaveTapped)

        testRow.action = { [weak self] in self?.testTapped() }
        newSessionRow.action = { [weak self] in self?.newSessionTapped() }
        aboutRow.action = { [weak self] in self?.infoTapped() }
        quitRow.action = { [weak self] in self?.quitTapped() }

        testKeyEquivalentButton.target = self
        testKeyEquivalentButton.action = #selector(testTapped)
        testKeyEquivalentButton.keyEquivalent = "t"
        testKeyEquivalentButton.keyEquivalentModifierMask = .command
        testKeyEquivalentButton.isHidden = true

        newSessionKeyEquivalentButton.target = self
        newSessionKeyEquivalentButton.action = #selector(newSessionTapped)
        newSessionKeyEquivalentButton.keyEquivalent = "n"
        newSessionKeyEquivalentButton.keyEquivalentModifierMask = .command
        newSessionKeyEquivalentButton.isHidden = true

        aboutKeyEquivalentButton.target = self
        aboutKeyEquivalentButton.action = #selector(infoTapped)
        aboutKeyEquivalentButton.keyEquivalent = "a"
        aboutKeyEquivalentButton.keyEquivalentModifierMask = .command
        aboutKeyEquivalentButton.isHidden = true

        quitKeyEquivalentButton.target = self
        quitKeyEquivalentButton.action = #selector(quitTapped)
        quitKeyEquivalentButton.keyEquivalent = "q"
        quitKeyEquivalentButton.keyEquivalentModifierMask = .command
        quitKeyEquivalentButton.isHidden = true

        refresh()
    }

    private func buildLayout() {
        serverLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerRow = NSStackView(views: [serverLabel, headerSpacer, serverToggle])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY

        statusMessageLabel.font = .systemFont(ofSize: 11.5)
        statusMessageLabel.textColor = .secondaryLabelColor

        let headerBlock = NSStackView(views: [headerRow, statusMessageLabel])
        headerBlock.orientation = .vertical
        headerBlock.alignment = .leading
        headerBlock.spacing = 4

        // Server details
        let portLabel = NSTextField(labelWithString: "Port")
        portLabel.font = .systemFont(ofSize: 12)
        portField.font = .systemFont(ofSize: 12)
        portField.bezelStyle = .roundedBezel
        portField.alignment = .right
        portField.translatesAutoresizingMaskIntoConstraints = false
        portField.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let portSpacer = NSView()
        portSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let portRow = NSStackView(views: [portLabel, portSpacer, portField])
        portRow.orientation = .horizontal
        portRow.alignment = .centerY

        urlLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        urlLabel.textColor = .secondaryLabelColor
        urlLabel.isSelectable = true
        urlLabel.lineBreakMode = .byTruncatingMiddle
        urlLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        copyURLButton.isBordered = false
        copyURLButton.bezelStyle = .regularSquare
        copyURLButton.imagePosition = .imageOnly
        copyURLButton.contentTintColor = .secondaryLabelColor
        (copyURLButton.cell as? NSButtonCell)?.imageScaling = .scaleProportionallyDown
        copyURLButton.translatesAutoresizingMaskIntoConstraints = false
        copyURLButton.widthAnchor.constraint(equalToConstant: 13).isActive = true
        copyURLButton.heightAnchor.constraint(equalToConstant: 13).isActive = true

        let urlRow = NSStackView(views: [urlLabel, copyURLButton])
        urlRow.orientation = .horizontal
        urlRow.alignment = .centerY
        urlRow.spacing = 5

        // Shown only once the HTTPS listener actually comes up (best-effort —
        // see `ServerController.isHTTPSActive`). Needed for a hosted
        // prototype's Safari testers specifically: unlike Chrome, Safari has
        // no response header that can let an https:// page fetch() a plain
        // http:// loopback endpoint, so the page's own fetch target has to
        // be https:// too, and each person visits this URL once to accept
        // the self-signed certificate before that fetch will succeed.
        httpsNoteLabel.font = .systemFont(ofSize: 10)
        httpsNoteLabel.textColor = .tertiaryLabelColor
        httpsNoteLabel.preferredMaxLayoutWidth = 264
        httpsNoteLabel.isSelectable = true

        endpointsLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        endpointsLabel.textColor = .secondaryLabelColor
        endpointsLabel.stringValue = "POST /v1/chat/completions\nGET  /v1/models\nGET  /v1/sessions"

        autoSummaryLabel.font = .systemFont(ofSize: 12)
        autoSummaryToggle.controlSize = .small
        let autoSummarySpacer = NSView()
        autoSummarySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let autoSummaryRow = NSStackView(views: [autoSummaryLabel, autoSummarySpacer, autoSummaryToggle])
        autoSummaryRow.orientation = .horizontal
        autoSummaryRow.alignment = .centerY

        autoSummaryNoteLabel.stringValue = "Auto-saves to disk; summarizes and continues automatically near the token limit."
        autoSummaryNoteLabel.font = .systemFont(ofSize: 10)
        autoSummaryNoteLabel.textColor = .tertiaryLabelColor
        autoSummaryNoteLabel.preferredMaxLayoutWidth = 264

        requestCountLabel.font = .systemFont(ofSize: 10.5)
        requestCountLabel.textColor = .tertiaryLabelColor

        let serverBlock = NSStackView(views: [
            portRow,
            urlRow,
            httpsNoteLabel,
            endpointsLabel,
            autoSummaryRow,
            autoSummaryNoteLabel,
            requestCountLabel,
        ])
        serverBlock.orientation = .vertical
        serverBlock.alignment = .leading
        serverBlock.spacing = 7

        // Instruction prompt — a persona/system prompt sent once, only when
        // a session is first created (see `ServerController.sessionInstructions`).
        // Lives here rather than in Test Chat itself, since it governs the
        // one shared app session regardless of which window talks to it.
        instructionsLabel.font = .systemFont(ofSize: 12)

        for button in [instructionsEditButton, instructionsCancelButton, instructionsSaveButton] {
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            (button.cell as? NSButtonCell)?.imageScaling = .scaleProportionallyDown
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 13).isActive = true
            button.heightAnchor.constraint(equalToConstant: 13).isActive = true
        }

        let instructionsLabelSpacer = NSView()
        instructionsLabelSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let instructionsLabelRow = NSStackView(views: [
            instructionsLabel, instructionsLabelSpacer,
            instructionsEditButton, instructionsCancelButton, instructionsSaveButton,
        ])
        instructionsLabelRow.orientation = .horizontal
        instructionsLabelRow.alignment = .centerY
        instructionsLabelRow.spacing = 6

        instructionsScrollView.hasVerticalScroller = true
        instructionsScrollView.borderType = .bezelBorder
        instructionsScrollView.translatesAutoresizingMaskIntoConstraints = false
        instructionsScrollView.widthAnchor.constraint(equalToConstant: 264).isActive = true
        instructionsScrollView.heightAnchor.constraint(equalToConstant: 56).isActive = true

        instructionsTextView.font = .systemFont(ofSize: 11.5)
        instructionsTextView.isRichText = false
        instructionsTextView.isEditable = false
        instructionsTextView.textColor = .tertiaryLabelColor
        instructionsTextView.isSelectable = true
        instructionsTextView.drawsBackground = true
        instructionsTextView.textContainerInset = NSSize(width: 4, height: 4)
        instructionsTextView.isVerticallyResizable = true
        instructionsTextView.isHorizontallyResizable = false
        instructionsTextView.autoresizingMask = [.width]
        instructionsTextView.textContainer?.widthTracksTextView = true
        instructionsScrollView.documentView = instructionsTextView

        instructionsNoteLabel.stringValue = "Sent once, when a new session starts. Counts toward the context window."
        instructionsNoteLabel.font = .systemFont(ofSize: 10)
        instructionsNoteLabel.textColor = .tertiaryLabelColor
        instructionsNoteLabel.preferredMaxLayoutWidth = 264

        let instructionsBlock = NSStackView(views: [instructionsLabelRow, instructionsScrollView, instructionsNoteLabel])
        instructionsBlock.orientation = .vertical
        instructionsBlock.alignment = .leading
        instructionsBlock.spacing = 5

        let menuBlock = NSStackView(views: [testRow, newSessionRow, aboutRow, quitRow])
        menuBlock.orientation = .vertical
        menuBlock.alignment = .leading
        menuBlock.spacing = 2

        let stack = NSStackView(views: [
            headerBlock,
            NSBox.separatorLine(),
            serverBlock,
            NSBox.separatorLine(),
            instructionsBlock,
            NSBox.separatorLine(),
            menuBlock,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentStack = stack

        // Padding is applied by insetting the stack from `view`'s edges here
        // (not via `stack.edgeInsets`) so that the row-width constraints
        // below, which pin to `stack.widthAnchor`, land inside that padding
        // instead of being measured against — and so overriding — it.
        let padding = popoverPadding
        view.addSubview(stack)
        view.addSubview(testKeyEquivalentButton)
        view.addSubview(newSessionKeyEquivalentButton)
        view.addSubview(aboutKeyEquivalentButton)
        view.addSubview(quitKeyEquivalentButton)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -padding),
        ])
        for row in [headerBlock, headerRow, serverBlock, portRow, urlRow, httpsNoteLabel, autoSummaryRow, instructionsBlock, instructionsLabelRow, menuBlock, testRow, newSessionRow, aboutRow, quitRow] {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    func refresh() {
        serverToggle.state = controller.isRunning ? .on : .off
        serverToggle.isEnabled = controller.status != .starting

        autoSummaryToggle.state = controller.autoSummaryEnabled ? .on : .off

        if case .error(let message) = controller.status {
            statusMessageLabel.stringValue = message
            statusMessageLabel.textColor = .systemRed
        } else if controller.isRunning {
            let tokens = controller.lastRequestTokenCount
            statusMessageLabel.stringValue = "\(controller.modelAvailabilityDescription) · \(tokens)/\(controller.contextWindowSize) tokens"
            statusMessageLabel.textColor = tokens == 0 ? .secondaryLabelColor : TokenGauge.color(forRatio: controller.tokenUsageRatio)
        } else {
            statusMessageLabel.stringValue = controller.modelAvailabilityDescription
            statusMessageLabel.textColor = .secondaryLabelColor
        }

        portField.isEnabled = !controller.isRunning
        // Don't clobber text the user is actively typing into the field.
        if portField.currentEditor() == nil {
            portField.stringValue = String(controller.port)
        }

        urlLabel.isHidden = !controller.isRunning
        urlLabel.stringValue = "http://127.0.0.1:\(controller.port)/v1"
        copyURLButton.isHidden = !controller.isRunning
        endpointsLabel.isHidden = !controller.isRunning

        if let httpsHealthURL = controller.httpsHealthURL {
            httpsNoteLabel.isHidden = false
            httpsNoteLabel.stringValue = "For Safari/hosted prototypes, visit \(httpsHealthURL) once to approve the local certificate."
        } else {
            httpsNoteLabel.isHidden = true
        }

        requestCountLabel.isHidden = !controller.isRunning
        requestCountLabel.stringValue = "\(controller.requestCount) request\(controller.requestCount == 1 ? "" : "s") served"

        // Re-check against the actual session state (not assumed) — an
        // external client can start/use this same session just as validly
        // as Test Chat can, so this is the only way to know for sure.
        controller.refreshAppSessionActiveState()
        // Never fight with an edit actually in progress — only resync the
        // read-only display from the model when the user isn't mid-edit.
        if !isEditingInstructions {
            instructionsTextView.string = controller.sessionInstructions
        }
        applyInstructionsButtonState()

        // Let the popover grow/shrink to fit — e.g. the URL/endpoints block
        // only exists while running, so there's no reason to reserve that
        // space while stopped. Measuring `contentStack.fittingSize` directly
        // (rather than the root `view`, which has no size-defining
        // constraints of its own beyond what the stack implies) is what
        // actually reflects hidden arranged subviews collapsing.
        view.layoutSubtreeIfNeeded()
        let height = contentStack.fittingSize.height + popoverPadding * 2
        preferredContentSize = NSSize(width: popoverWidth, height: height)
    }

    @objc private func serverToggleChanged(_ sender: NSSwitch) {
        if sender.state == .on {
            applyPortFromField()
            controller.start()
        } else {
            controller.stop()
        }
        refresh()
    }

    @objc private func autoSummaryToggleChanged(_ sender: NSSwitch) {
        controller.autoSummaryEnabled = sender.state == .on
        refresh()
    }

    @objc private func quitTapped() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func infoTapped() {
        aboutWindowController.show()
    }

    @objc private func testTapped() {
        let windowController = testChatWindowController ?? TestChatWindowController(controller: controller)
        testChatWindowController = windowController
        windowController.show()
    }

    /// Ends the shared app session and resets the instruction prompt back to
    /// its default — a full clean slate for the next persona you try, rather
    /// than silently carrying over whatever was last typed. Briefly confirms
    /// in the status line, matching the copy-URL button's checkmark pattern.
    @objc private func newSessionTapped() {
        controller.startNewSession()
        isEditingInstructions = false
        refresh()
        statusMessageLabel.stringValue = "New session started."
        statusMessageLabel.textColor = .secondaryLabelColor
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.refresh()
        }
    }

    /// Enters edit mode: the box becomes editable, and the single pencil
    /// button is replaced by explicit cancel/save buttons — there's no
    /// implicit "typing already saved it" state in between.
    @objc private func instructionsEditTapped() {
        isEditingInstructions = true
        instructionsTextView.isEditable = true
        instructionsTextView.textColor = .labelColor
        applyInstructionsButtonState()
        view.window?.makeFirstResponder(instructionsTextView)
    }

    /// Discards whatever's currently typed and reverts the box to the last
    /// actually-saved instructions.
    @objc private func instructionsCancelTapped() {
        instructionsTextView.string = controller.sessionInstructions
        exitInstructionsEditMode()
    }

    /// The only way `sessionInstructions` actually gets committed — typing
    /// alone never saves, so there's no ambiguity about whether an edit
    /// "took."
    @objc private func instructionsSaveTapped() {
        controller.sessionInstructions = instructionsTextView.string
        exitInstructionsEditMode()
    }

    private func exitInstructionsEditMode() {
        isEditingInstructions = false
        instructionsTextView.isEditable = false
        instructionsTextView.textColor = .tertiaryLabelColor
        applyInstructionsButtonState()
    }

    /// Which of the three buttons show, and whether the pencil itself is
    /// usable — edits are pointless (and disabled) once the shared session
    /// actually exists, since instructions only apply at session creation.
    private func applyInstructionsButtonState() {
        instructionsEditButton.isHidden = isEditingInstructions
        instructionsCancelButton.isHidden = !isEditingInstructions
        instructionsSaveButton.isHidden = !isEditingInstructions
        instructionsEditButton.isEnabled = !controller.isAppSessionActive
    }

    @objc private func copyURLTapped() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlLabel.stringValue, forType: .string)

        // Brief checkmark confirmation, then back to the copy glyph.
        copyURLButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.copyURLButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy URL")
        }
    }

    @objc private func portFieldChanged() {
        applyPortFromField()
    }

    private func applyPortFromField() {
        guard let value = UInt16(portField.stringValue.trimmingCharacters(in: .whitespaces)), value > 0 else {
            portField.stringValue = String(controller.port)
            return
        }
        controller.applyPort(value)
        refresh()
    }
}
