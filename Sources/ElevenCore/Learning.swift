import Foundation

/// Local, on-disk personalization. Only counts of words the user actually
/// committed are stored; no screen text ever reaches this file.
public final class LearningStore: @unchecked Sendable {
    private struct Payload: Codable {
        var version: Int
        var words: [String: Int]
        var transitions: [String: Int]
    }

    public static let maxWords = 40_000
    public static let maxTransitions = 60_000

    private let lock = NSLock()
    private var words: [String: Int] = [:]
    private var transitions: [String: Int] = [:]
    private var dirty = false
    private var lastSave = Date.distantPast
    private let url: URL?
    private let saveQueue = DispatchQueue(label: "com.eleven.inputmethod.learning.save", qos: .utility)

    public init(url: URL? = LearningStore.defaultURL) {
        self.url = url
        load()
    }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("ElevenInput", isDirectory: true)
            .appendingPathComponent("learning.json")
    }

    // MARK: - Reading

    public func boost(word: String, previous: String?) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let wordCount = words[word] ?? 0
        var score = 0.7 * log1p(Double(wordCount))
        if let previous = previous, !previous.isEmpty {
            let key = transitionKey(previous, word)
            score += 1.2 * log1p(Double(transitions[key] ?? 0))
        }
        return score
    }

    public func isKnown(word: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (words[word] ?? 0) > 0
    }

    // MARK: - Writing

    public func record(word: String, previous: String?) {
        guard !word.isEmpty else { return }
        lock.lock()
        words[word, default: 0] += 1
        if let previous = previous, !previous.isEmpty {
            transitions[transitionKey(previous, word), default: 0] += 1
        }
        dirty = true
        let shouldSave = Date().timeIntervalSince(lastSave) > 8
        if shouldSave { lastSave = Date() }
        lock.unlock()

        if shouldSave {
            saveQueue.async { [weak self] in self?.save() }
        }
        pruneIfNeeded()
    }

    public func clear() {
        lock.lock()
        words.removeAll()
        transitions.removeAll()
        dirty = true
        lock.unlock()
        save()
    }

    public func save() {
        lock.lock()
        guard dirty, let url = url else { lock.unlock(); return }
        dirty = false
        let payload = Payload(version: 1, words: words, transitions: transitions)
        lock.unlock()

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = []
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
        } catch {
            // Personalization is best-effort; never disturb typing.
        }
    }

    private func pruneIfNeeded() {
        lock.lock()
        guard words.count > LearningStore.maxWords || transitions.count > LearningStore.maxTransitions else {
            lock.unlock()
            return
        }
        let keptWords = words.sorted { $0.value > $1.value }.prefix(LearningStore.maxWords * 3 / 4)
        words = Dictionary(uniqueKeysWithValues: keptWords.map { ($0.key, $0.value) })
        let keptTransitions = transitions.sorted { $0.value > $1.value }.prefix(LearningStore.maxTransitions * 3 / 4)
        transitions = Dictionary(uniqueKeysWithValues: keptTransitions.map { ($0.key, $0.value) })
        lock.unlock()
    }

    // MARK: - Persistence

    private func load() {
        guard let url = url, let data = try? Data(contentsOf: url) else { return }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        words = payload.words
        transitions = payload.transitions
        pruneIfNeeded()
    }

    private func transitionKey(_ previous: String, _ word: String) -> String {
        previous + "\u{1}" + word
    }
}
