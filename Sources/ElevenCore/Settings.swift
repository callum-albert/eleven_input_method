import Foundation

/// User preferences, stored in the app's UserDefaults domain.
public final class ElevenSettings: @unchecked Sendable {
    public static let shared = ElevenSettings()

    private enum Key {
        static let accessibility = "enableAccessibility"
        static let ocr = "enableScreenOCR"
        static let learning = "enableLearning"
        static let clipboard = "enableClipboard"
        static let hints = "showContextHints"
        static let candidates = "candidateLimit"
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.accessibility: true,
            Key.ocr: false,
            Key.learning: true,
            Key.clipboard: false,
            Key.hints: true,
            Key.candidates: 9,
        ])
    }

    public var enableAccessibility: Bool {
        get { bool(Key.accessibility) }
        set { set(Key.accessibility, newValue) }
    }

    public var enableOCR: Bool {
        get { bool(Key.ocr) }
        set { set(Key.ocr, newValue) }
    }

    public var enableLearning: Bool {
        get { bool(Key.learning) }
        set { set(Key.learning, newValue) }
    }

    public var enableClipboard: Bool {
        get { bool(Key.clipboard) }
        set { set(Key.clipboard, newValue) }
    }

    public var showContextHints: Bool {
        get { bool(Key.hints) }
        set { set(Key.hints, newValue) }
    }

    public var candidateLimit: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            let value = defaults.integer(forKey: Key.candidates)
            return min(9, max(3, value))
        }
        set {
            lock.lock()
            defaults.set(min(9, max(3, newValue)), forKey: Key.candidates)
            lock.unlock()
        }
    }

    private func bool(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return defaults.bool(forKey: key)
    }

    private func set(_ key: String, _ value: Bool) {
        lock.lock()
        defaults.set(value, forKey: key)
        lock.unlock()
    }
}
