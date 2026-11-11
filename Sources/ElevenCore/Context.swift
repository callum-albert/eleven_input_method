import Foundation

public struct ContextSource: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let accessibility = ContextSource(rawValue: 1 << 0)
    public static let screenOCR = ContextSource(rawValue: 1 << 1)
    public static let committed = ContextSource(rawValue: 1 << 2)
    public static let clipboard = ContextSource(rawValue: 1 << 3)
}

/// A point-in-time view of the text around the user, plus what they just typed.
/// Everything here lives in memory only.
public struct ContextSnapshot: Sendable {
    /// Text to the left of the insertion point in the focused editor.
    public var beforeCursor: String = ""
    /// Text visible in the frontmost window (accessibility tree or OCR).
    public var windowText: String = ""
    /// Text this input method has committed recently.
    public var committed: String = ""
    /// Opt-in clipboard contents.
    public var clipboard: String = ""
    public var sources: ContextSource = []
    public var capturedAt: Date = .distantPast
    public var appName: String = ""

    public init() {}

    public var isEmpty: Bool {
        beforeCursor.isEmpty && windowText.isEmpty && committed.isEmpty && clipboard.isEmpty
    }
}

public struct RankingWeights: Sendable {
    public var exactBonus: Double = 8.0
    public var partialPenaltyPerChar: Double = 0.35
    public var contextBefore: Double = 2.6
    public var contextWindow: Double = 1.1
    public var contextCommitted: Double = 1.6
    public var contextClipboard: Double = 0.3
    public var contextGain: Double = 3.0
    public var contextCap: Double = 11.0
    public var adjacencyGain: Double = 2.0
    public var learnedWordGain: Double = 0.7
    public var learnedTransitionGain: Double = 1.2
    public var compositionWordPenalty: Double = 9.0
    public var compositionLengthBonus: Double = 3.0
    public var compositionSingleCharPenalty: Double = 2.0

    public init() {}
}

/// Scores how well a candidate word fits the harvested text.
/// This is the "pick 构件 because the screen already says 构件" part.
public final class ContextModel {
    public let snapshot: ContextSnapshot
    private let weights: RankingWeights
    private let before: String
    private let window: String
    private let committed: String
    private let clipboard: String
    private enum Field: Int { case before, window, committed, clipboard }
    private var cache: [String: Int] = [:]

    public init(snapshot: ContextSnapshot, weights: RankingWeights) {
        self.snapshot = snapshot
        self.weights = weights
        // Budgets keep per-keystroke work tiny and predictable.
        self.before = String(snapshot.beforeCursor.suffix(900))
        self.window = String(snapshot.windowText.suffix(2600))
        self.committed = String(snapshot.committed.suffix(700))
        self.clipboard = String(snapshot.clipboard.prefix(400))
    }

    public struct Evaluation {
        public var score: Double = 0
        public var hints: [String] = []
        public var beforeCount = 0
        public var windowCount = 0
        public var committedCount = 0
        public var adjacency = 0
    }

    public func evaluate(word: String, previousCharacter: Character?) -> Evaluation {
        var result = Evaluation()
        guard !word.isEmpty, !snapshot.isEmpty else { return result }

        let nBefore = count(word, field: .before)
        let nWindow = count(word, field: .window)
        let nCommitted = count(word, field: .committed)
        let nClipboard = count(word, field: .clipboard)

        result.beforeCount = nBefore
        result.windowCount = nWindow
        result.committedCount = nCommitted

        var tf = 0.0
        if nBefore > 0 { tf += Double(nBefore) * weights.contextBefore }
        if nWindow > 0 { tf += Double(nWindow) * weights.contextWindow }
        if nCommitted > 0 { tf += Double(nCommitted) * weights.contextCommitted }
        if nClipboard > 0 { tf += Double(nClipboard) * weights.contextClipboard }

        var score = min(weights.contextCap, weights.contextGain * log1p(tf))

        // "接续": the word follows the character right before the caret.
        if let previous = previousCharacter {
            let pair = String(previous) + word
            let n = count(pair, field: .before)
            if n > 0 {
                result.adjacency = n
                score += weights.adjacencyGain * log1p(Double(n))
            }
        }

        result.score = score

        if nBefore > 0 { result.hints.append("前文 ×\(nBefore)") }
        if nWindow > 0 { result.hints.append("屏幕 ×\(nWindow)") }
        if nCommitted > 0 { result.hints.append("刚输入") }
        if result.adjacency > 0 { result.hints.append("接续") }
        if nClipboard > 0 { result.hints.append("剪贴板") }
        return result
    }

    private func count(_ needle: String, field: Field) -> Int {
        let haystack: String
        switch field {
        case .before: haystack = before
        case .window: haystack = window
        case .committed: haystack = committed
        case .clipboard: haystack = clipboard
        }
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
        let cacheKey = "\(field.rawValue)|\(needle)"
        if let cached = cache[cacheKey] { return cached }
        let text = haystack as NSString
        let pattern = needle as NSString
        var total = 0
        var location = 0
        while location < text.length {
            let found = text.range(of: pattern as String, options: [], range: NSRange(location: location, length: text.length - location))
            if found.location == NSNotFound { break }
            total += 1
            location = found.location + 1
            if total > 256 { break }
        }
        cache[cacheKey] = total
        return total
    }
}

/// Thread-safe in-memory ring buffer of recent text. Nothing is written to disk.
public final class ContextStore: @unchecked Sendable {
    private let lock = NSLock()
    private var beforeCursor = ""
    private var windowText = ""
    private var clipboard = ""
    private var committed = ""
    private var capturedAt = Date.distantPast
    private var appName = ""
    private var sources: ContextSource = []

    public init() {}

    public func update(
        before: String,
        window: String,
        clipboard: String = "",
        appName: String,
        sources: ContextSource
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.beforeCursor = String(before.suffix(2000))
        self.windowText = String(window.suffix(8000))
        self.clipboard = clipboard
        self.capturedAt = Date()
        self.appName = appName
        self.sources = sources
    }

    /// Text committed by this input method is appended immediately: it is the
    /// highest-signal, zero-cost context we have.
    public func appendCommitted(_ text: String) {
        guard !text.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        committed = String((committed + text).suffix(1200))
        beforeCursor = String((beforeCursor + text).suffix(2200))
        sources.insert(.committed)
    }

    public func snapshot(maxAge: TimeInterval = 180) -> ContextSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var result = ContextSnapshot()
        result.committed = committed
        result.sources = sources
        result.appName = appName
        result.capturedAt = capturedAt

        if Date().timeIntervalSince(capturedAt) <= maxAge {
            result.beforeCursor = beforeCursor
            result.windowText = windowText
            result.clipboard = clipboard
        } else {
            // Stale screen text is dropped; committed text survives.
            result.sources.remove([.accessibility, .screenOCR, .clipboard])
        }
        return result
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        beforeCursor = ""
        windowText = ""
        clipboard = ""
        committed = ""
        capturedAt = .distantPast
        appName = ""
        sources = []
    }
}
