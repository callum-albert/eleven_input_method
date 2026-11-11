import AppKit
import ApplicationServices
import ElevenCore

final class DemoWindow: NSPanel, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private var engine: PinyinEngine?
    private let harvester = ContextHarvester()
    private let inputField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "⌃⌥Space 唤起 · ↑↓ 选择 · ↵ 提交 · esc 关闭")
    private var candidates: [Candidate] = []
    private var previousApp: NSRunningApplication?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        title = "拾文 · 演示"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        contentView = effect

        inputField.font = .systemFont(ofSize: 24, weight: .regular)
        inputField.placeholderString = "输入拼音，例如 goujian"
        inputField.isBordered = false
        inputField.drawsBackground = false
        inputField.focusRingType = .none
        inputField.delegate = self

        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("candidate"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 10)
        hintLabel.textColor = .tertiaryLabelColor

        for view in [inputField, scrollView, statusLabel, hintLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(view)
        }

        NSLayoutConstraint.activate([
            inputField.topAnchor.constraint(equalTo: effect.topAnchor, constant: 42),
            inputField.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 24),
            inputField.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -24),
            inputField.heightAnchor.constraint(equalToConstant: 40),

            scrollView.topAnchor.constraint(equalTo: inputField.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -10),

            statusLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -24),
            statusLabel.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -4),
            statusLabel.heightAnchor.constraint(equalToConstant: 16),

            hintLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 24),
            hintLabel.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10),
        ])

        engine = IMEDemoEngine.make(harvester: harvester)
    }

    override var canBecomeKey: Bool { true }

    func toggle() {
        if isVisible {
            closePanel()
            return
        }

        // Harvest *before* we become frontmost, so the context belongs to the
        // app the user was actually looking at.
        if !AXIsProcessTrusted() {
            AccessibilityContext.requestTrust()
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        harvester.refreshFrontmost(wait: true)
        statusLabel.stringValue = "上下文：" + harvester.lastSummary

        inputField.stringValue = ""
        candidates = []
        tableView.reloadData()
        NSApp.activate(ignoringOtherApps: true)
        center()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(inputField)
    }

    private func closePanel() {
        orderOut(nil)
        NSApp.hide(nil)
        previousApp?.activate()
    }

    // MARK: - Input

    func controlTextDidChange(_ notification: Notification) {
        let query = inputField.stringValue
        candidates = query.isEmpty ? [] : (engine?.candidates(for: query, limit: 8) ?? [])
        tableView.reloadData()
        if !candidates.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateStatus()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitSelected()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closePanel()
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !candidates.isEmpty else { return }
        let count = candidates.count
        let next = ((tableView.selectedRow + delta) % count + count) % count
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        commitSelected()
    }

    private func commitSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < candidates.count else {
            closePanel()
            return
        }
        let text = candidates[row].text
        engine?.recordCommit(text)
        harvester.appendCommitted(text)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        closePanel()

        if AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                Self.paste()
            }
        }
    }

    private static func paste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cghidEventTap)
    }

    private func updateStatus() {
        var pieces: [String] = []
        if let first = candidates.first, let hint = first.hint {
            pieces.append("首选 \(first.text) · \(hint)")
        }
        let snapshot = harvester.snapshot()
        if snapshot.isEmpty {
            pieces.append(AXIsProcessTrusted() ? "未读到窗口文字" : "未授权辅助功能（仅按词频排序）")
        } else {
            pieces.append("前文 \(snapshot.beforeCursor.count) 字 · 窗口 \(snapshot.windowText.count) 字")
        }
        statusLabel.stringValue = pieces.joined(separator: "  ·  ")
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        candidates.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("cell")
        let cell: CandidateCell
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? CandidateCell {
            cell = reused
        } else {
            cell = CandidateCell()
            cell.identifier = identifier
        }
        cell.configure(index: row + 1, candidate: candidates[row])
        return cell
    }
}

private final class CandidateCell: NSTableCellView {
    private let number = NSTextField(labelWithString: "")
    private let word = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        number.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        number.textColor = .tertiaryLabelColor
        word.font = .systemFont(ofSize: 18, weight: .medium)
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .controlAccentColor
        hint.alignment = .right

        for view in [number, word, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            number.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            number.centerYAnchor.constraint(equalTo: centerYAnchor),
            number.widthAnchor.constraint(equalToConstant: 18),
            word.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 6),
            word.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: word.trailingAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(index: Int, candidate: Candidate) {
        number.stringValue = "\(index)"
        word.stringValue = candidate.text
        hint.stringValue = candidate.hint ?? ""
    }
}

enum IMEDemoEngine {
    static func make(harvester: ContextHarvester) -> PinyinEngine? {
        do {
            let dictionary = try PinyinDictionary.loadDefault()
            let learning = LearningStore()
            return PinyinEngine(
                dictionary: dictionary,
                learning: learning,
                contextProvider: { harvester.snapshot() }
            )
        } catch {
            NSLog("ElevenDemo: cannot load dictionary: \(error)")
            return nil
        }
    }
}
