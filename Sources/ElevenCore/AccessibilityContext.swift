import Foundation
import ApplicationServices

/// Reads text from the focused window through the Accessibility API.
///
/// This is the cheap primary source: exact text, no screenshots, no OCR, no GPU,
/// and only a handful of IPC calls per harvest.
public enum AccessibilityContext {
    public struct Harvest {
        public var before: String = ""
        public var window: String = ""
        /// Text of the focused element itself, useful for debugging.
        public var focused: String = ""
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    public static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static func harvest(pid: pid_t, maxBefore: Int = 1200, maxWindow: Int = 8000, deadline: TimeInterval = 0.12) -> Harvest {
        var harvest = Harvest()
        guard pid > 0 else { return harvest }
        let started = Date()

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedAny = focusedRef,
              CFGetTypeID(focusedAny) == AXUIElementGetTypeID()
        else {
            harvest.window = windowText(app: app, maxChars: maxWindow, deadline: deadline, started: started)
            return harvest
        }
        let focused = focusedAny as! AXUIElement

        // 1. The editor's full value + selection gives exact text on both sides
        //    of the caret.
        if let value = stringAttribute(focused, kAXValueAttribute), !value.isEmpty {
            harvest.focused = value
            var caret = (value as NSString).length
            if let rangeRef = copyAttribute(focused, kAXSelectedTextRangeAttribute as String) {
                var range = CFRange(location: 0, length: 0)
                let axValue = rangeRef as! AXValue
                if AXValueGetValue(axValue, .cfRange, &range), range.location != kCFNotFound {
                    caret = max(0, min(range.location, (value as NSString).length))
                }
            } else if let selected = stringAttribute(focused, kAXSelectedTextAttribute) {
                // No selection range: treat the selected text as the caret anchor.
                let nsValue = value as NSString
                let found = nsValue.range(of: selected)
                if found.location != NSNotFound {
                    caret = max(0, found.location)
                }
            }
            let nsValue = value as NSString
            let prefix = nsValue.substring(to: caret)
            let suffix = nsValue.substring(from: caret)
            harvest.before = String(prefix.suffix(maxBefore))
            if harvest.window.count < maxWindow {
                harvest.window = String((harvest.before + suffix).prefix(maxWindow))
            }
        }

        // 2. Fallbacks for apps that do not expose a value (web views, canvases).
        if harvest.before.isEmpty {
            if let selected = stringAttribute(focused, kAXSelectedTextAttribute), !selected.isEmpty {
                harvest.before = String(selected.suffix(maxBefore))
            }
        }

        // 3. The visible window tree is the best proxy for "what is on screen".
        if harvest.window.count < maxWindow / 2, Date().timeIntervalSince(started) < deadline {
            let window = windowText(app: app, maxChars: maxWindow, deadline: deadline, started: started)
            if !window.isEmpty {
                harvest.window = harvest.window.isEmpty ? window : harvest.window + "\n" + window
            }
        }

        harvest.window = String(harvest.window.prefix(maxWindow))
        return harvest
    }

    // MARK: - Window walk

    private static func windowText(app: AXUIElement, maxChars: Int, deadline: TimeInterval, started: Date) -> String {
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowAny = windowRef,
              CFGetTypeID(windowAny) == AXUIElementGetTypeID()
        else { return "" }
        let window = windowAny as! AXUIElement

        var queue: [AXUIElement] = [window]
        var visited = Set<CFHashCode>()
        var pieces: [String] = []
        var characters = 0
        var nodes = 0

        while !queue.isEmpty {
            if nodes > 600 || characters >= maxChars { break }
            if nodes % 24 == 0, Date().timeIntervalSince(started) > deadline { break }

            let element = queue.removeFirst()
            let hash = CFHash(element)
            if visited.contains(hash) { continue }
            visited.insert(hash)
            nodes += 1

            if let role = stringAttribute(element, kAXRoleAttribute) {
                let textual = role == (kAXStaticTextRole as String)
                    || role == (kAXTextFieldRole as String)
                    || role == (kAXTextAreaRole as String)
                    || role == "AXWebArea"
                if textual {
                    if let value = stringAttribute(element, kAXValueAttribute), !value.isEmpty {
                        pieces.append(value)
                        characters += value.count
                    } else if let title = stringAttribute(element, kAXTitleAttribute), !title.isEmpty {
                        pieces.append(title)
                        characters += title.count
                    }
                }
            }

            if let childrenRef = copyAttribute(element, kAXChildrenAttribute as String),
               let children = childrenRef as? [Any] {
                for child in children {
                    if CFGetTypeID(child as CFTypeRef) == AXUIElementGetTypeID() {
                        queue.append(child as! AXUIElement)
                    }
                }
            }
        }

        return pieces.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        copyAttribute(element, attribute) as? String
    }
}
