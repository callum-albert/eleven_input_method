import Foundation
import AppKit
import ElevenCore

enum Log {
    private static let lock = NSLock()
    private static let url: URL = {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library.appendingPathComponent("Logs/ElevenInput.log")
    }()

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

/// Process-wide services shared by every input session.
final class IMEShared {
    static let shared = IMEShared()

    let settings = ElevenSettings.shared
    let harvester = ContextHarvester()
    private(set) var dictionary: PinyinDictionary?
    private(set) var learning: LearningStore?

    private init() {
        do {
            let dictionary = try PinyinDictionary.loadDefault()
            self.dictionary = dictionary
            Log.write("dictionary loaded: \(dictionary.entries.count) entries, max key \(dictionary.maxKeyLength)")
        } catch {
            Log.write("dictionary failed to load: \(error)")
        }

        if settings.enableLearning {
            learning = LearningStore()
        }
        syncSettings()
    }

    func syncSettings() {
        harvester.enableAccessibility = settings.enableAccessibility
        harvester.enableOCR = settings.enableOCR
        harvester.enableClipboard = settings.enableClipboard
    }

    func makeEngine() -> PinyinEngine? {
        guard let dictionary = dictionary else { return nil }
        let store = settings.enableLearning ? (learning ?? LearningStore()) : nil
        return PinyinEngine(
            dictionary: dictionary,
            learning: store,
            contextProvider: { [weak self] in
                self?.harvester.snapshot() ?? ContextSnapshot()
            }
        )
    }

    func flushLearning() {
        learning?.save()
    }
}
