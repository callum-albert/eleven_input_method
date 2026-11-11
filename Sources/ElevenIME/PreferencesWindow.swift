import AppKit
import ElevenCore

/// Minimal settings window. Reachable from the input menu ("拾文输入法设置…").
final class PreferencesWindowController: NSObject, NSWindowDelegate {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?
    private var accessibilityStatus: NSTextField?
    private var screenStatus: NSTextField?
    private var harvestNote: NSTextField?

    func show() {
        if window == nil { build() }
        refreshStatus()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshStatus()
    }

    // MARK: - UI

    private func build() {
        let settings = IMEShared.shared.settings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "拾文输入法"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView()
        window.contentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
        ])

        stack.addArrangedSubview(title("上下文输入法", font: .systemFont(ofSize: 17, weight: .semibold)))
        stack.addArrangedSubview(label(
            "只在开始输入时读取一次当前窗口的文字，用来判断多音字/同音词。不实时截屏，不联网，不保存屏幕内容。",
            size: 11,
            color: .secondaryLabelColor
        ))
        stack.addArrangedSubview(spacer(6))

        stack.addArrangedSubview(sectionTitle("上下文来源"))

        let axRow = NSStackView()
        axRow.orientation = .horizontal
        axRow.spacing = 8
        let axToggle = checkbox("读取屏幕文字（辅助功能）", on: settings.enableAccessibility, action: #selector(toggleAccessibility(_:)))
        accessibilityStatus = label("", size: 11, color: .secondaryLabelColor)
        let axButton = button("打开设置", action: #selector(openAccessibilitySettings))
        axRow.addArrangedSubview(axToggle)
        axRow.addArrangedSubview(accessibilityStatus!)
        axRow.addArrangedSubview(axButton)
        stack.addArrangedSubview(axRow)

        let ocrRow = NSStackView()
        ocrRow.orientation = .horizontal
        ocrRow.spacing = 8
        let ocrToggle = checkbox("截图 OCR 兜底（屏幕录制权限）", on: settings.enableOCR, action: #selector(toggleOCR(_:)))
        screenStatus = label("", size: 11, color: .secondaryLabelColor)
        let ocrButton = button("打开设置", action: #selector(openScreenCaptureSettings))
        ocrRow.addArrangedSubview(ocrToggle)
        ocrRow.addArrangedSubview(screenStatus!)
        ocrRow.addArrangedSubview(ocrButton)
        stack.addArrangedSubview(ocrRow)

        stack.addArrangedSubview(checkbox("剪贴板作为弱提示", on: settings.enableClipboard, action: #selector(toggleClipboard(_:))))
        stack.addArrangedSubview(spacer(2))
        harvestNote = label("", size: 10, color: .tertiaryLabelColor)
        stack.addArrangedSubview(harvestNote!)

        stack.addArrangedSubview(spacer(8))
        stack.addArrangedSubview(sectionTitle("本地学习"))
        stack.addArrangedSubview(checkbox("记住我常打的词（仅保存在本机）", on: settings.enableLearning, action: #selector(toggleLearning(_:))))
        stack.addArrangedSubview(button("清除学习数据", action: #selector(clearLearning)))

        stack.addArrangedSubview(spacer(8))
        stack.addArrangedSubview(sectionTitle("显示"))
        stack.addArrangedSubview(checkbox("在候选词下方显示来源（如 屏幕 ×12）", on: settings.showContextHints, action: #selector(toggleHints(_:))))

        stack.addArrangedSubview(spacer(10))
        let done = button("完成", action: #selector(closeWindow))
        done.keyEquivalent = "\r"
        stack.addArrangedSubview(done)

        self.window = window
        refreshStatus()
    }

    private func refreshStatus() {
        accessibilityStatus?.stringValue = AccessibilityContext.isTrusted ? "已授权" : "未授权"
        accessibilityStatus?.textColor = AccessibilityContext.isTrusted ? .systemGreen : .systemOrange
        screenStatus?.stringValue = ScreenOCR.hasPermission ? "已授权" : "未授权"
        screenStatus?.textColor = ScreenOCR.hasPermission ? .systemGreen : .secondaryLabelColor
        let settings = IMEShared.shared.settings
        harvestNote?.stringValue = settings.enableOCR
            ? "当前策略：辅助功能优先，取不到文字时才截取一次窗口（≥4 秒节流）。"
            : "当前策略：仅使用辅助功能读取文字，不截屏。"
    }

    // MARK: - Actions

    @objc private func toggleAccessibility(_ sender: NSButton) {
        IMEShared.shared.settings.enableAccessibility = sender.state == .on
        IMEShared.shared.syncSettings()
        if sender.state == .on { AccessibilityContext.requestTrust() }
        refreshStatus()
    }

    @objc private func toggleOCR(_ sender: NSButton) {
        IMEShared.shared.settings.enableOCR = sender.state == .on
        IMEShared.shared.syncSettings()
        if sender.state == .on { ScreenOCR.requestPermission() }
        refreshStatus()
    }

    @objc private func toggleClipboard(_ sender: NSButton) {
        IMEShared.shared.settings.enableClipboard = sender.state == .on
        IMEShared.shared.syncSettings()
    }

    @objc private func toggleLearning(_ sender: NSButton) {
        IMEShared.shared.settings.enableLearning = sender.state == .on
    }

    @objc private func toggleHints(_ sender: NSButton) {
        IMEShared.shared.settings.showContextHints = sender.state == .on
    }

    @objc private func clearLearning() {
        IMEShared.shared.learning?.clear()
        let alert = NSAlert()
        alert.messageText = "已清除本地学习数据"
        alert.informativeText = "输入法会重新开始学习你常用的词。"
        alert.runModal()
    }

    @objc private func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    @objc private func openScreenCaptureSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    @objc private func closeWindow() {
        window?.close()
    }

    private func open(_ string: String) {
        if let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Small builders

    private func title(_ text: String, font: NSFont) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        return field
    }

    private func label(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size)
        field.textColor = color
        return field
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11, weight: .semibold)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func checkbox(_ text: String, on: Bool, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: text, target: self, action: action)
        button.state = on ? .on : .off
        button.font = .systemFont(ofSize: 12)
        return button
    }

    private func button(_ text: String, action: Selector) -> NSButton {
        let button = NSButton(title: text, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12)
        return button
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }
}
