import Foundation
import AppKit

/// Orchestrates cheap, event-driven context harvesting.
///
/// Policy (all tunable):
///  - Harvest when a composition starts, at most once every ~1.2s.
///  - Accessibility first; OCR only if AX returned almost nothing.
///  - OCR is throttled to once every few seconds and is opt-in.
///  - Only the focused window is read; nothing is captured while idle.
public final class ContextHarvester: @unchecked Sendable {
    public var enableAccessibility = true
    public var enableOCR = false
    public var enableClipboard = false
    public var minInterval: TimeInterval = 1.2
    public var ocrMinInterval: TimeInterval = 4.0

    private let store = ContextStore()
    private let queue = DispatchQueue(label: "com.eleven.inputmethod.harvest", qos: .utility)
    private let lock = NSLock()
    private var inFlight = false
    private var lastRefresh = Date.distantPast
    private var lastOCR = Date.distantPast
    private var lastHarvestSummary = ""

    public init() {}

    public func snapshot() -> ContextSnapshot {
        store.snapshot()
    }

    public func appendCommitted(_ text: String) {
        store.appendCommitted(text)
    }

    public func clear() {
        store.clear()
    }

    public var lastSummary: String {
        lock.lock()
        defer { lock.unlock() }
        return lastHarvestSummary
    }

    /// Kicks off a background harvest for the frontmost application.
    public func refreshFrontmost(force: Bool = false, wait: Bool = false) {
        guard enableAccessibility || enableOCR || enableClipboard else { return }
        let app = NSWorkspace.shared.frontmostApplication
        guard let pid = app?.processIdentifier else { return }
        refresh(pid: pid, appName: app?.localizedName ?? "", force: force, wait: wait)
    }

    public func refresh(pid: pid_t, appName: String = "", force: Bool = false, wait: Bool = false) {
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return }

        lock.lock()
        if inFlight {
            lock.unlock()
            return
        }
        if !force, Date().timeIntervalSince(lastRefresh) < minInterval {
            lock.unlock()
            return
        }
        inFlight = true
        lastRefresh = Date()
        let accessibility = enableAccessibility
        let ocr = enableOCR
        let clipboard = enableClipboard
        lock.unlock()

        let semaphore = wait ? DispatchSemaphore(value: 0) : nil

        queue.async { [weak self] in
            guard let self = self else { return }
            var before = ""
            var window = ""
            var sources: ContextSource = []
            var summaryParts: [String] = []

            if accessibility {
                let harvest = AccessibilityContext.harvest(pid: pid)
                before = harvest.before
                window = harvest.window
                if !before.isEmpty || !window.isEmpty {
                    sources.insert(.accessibility)
                    summaryParts.append("AX \(before.count + window.count)字")
                } else {
                    summaryParts.append("AX 无文本")
                }
            }

            if ocr, window.count < 80 {
                self.lock.lock()
                let elapsed = Date().timeIntervalSince(self.lastOCR)
                self.lock.unlock()
                if elapsed > self.ocrMinInterval {
                    self.lock.lock()
                    self.lastOCR = Date()
                    self.lock.unlock()
                    if let text = ScreenOCR.captureText(pid: pid) {
                        window += (window.isEmpty ? "" : "\n") + text
                        sources.insert(.screenOCR)
                        summaryParts.append("OCR \(text.count)字")
                    } else {
                        summaryParts.append("OCR 无结果")
                    }
                }
            }

            var clipboardText = ""
            if clipboard {
                if let text = NSPasteboard.general.string(forType: .string),
                   text.count > 1, text.count < 800,
                   text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
                    clipboardText = text
                    sources.insert(.clipboard)
                    summaryParts.append("剪贴板")
                }
            }

            self.store.update(
                before: before,
                window: window,
                clipboard: clipboardText,
                appName: appName,
                sources: sources
            )

            self.lock.lock()
            self.inFlight = false
            self.lastHarvestSummary = summaryParts.joined(separator: " · ")
            self.lock.unlock()
            semaphore?.signal()
        }

        if let semaphore = semaphore {
            _ = semaphore.wait(timeout: .now() + 0.3)
        }
    }
}
