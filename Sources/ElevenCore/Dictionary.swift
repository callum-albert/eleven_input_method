import Foundation

public struct DictEntry: Sendable, Equatable {
    /// Toneless, separator-free pinyin, e.g. "goujian".
    public let key: String
    /// The Chinese word, e.g. "构件".
    public let word: String
    /// Unigram frequency (roughly a corpus count).
    public let freq: Float

    public init(key: String, word: String, freq: Float) {
        self.key = key
        self.word = word
        self.freq = freq
    }

    public var logFreq: Double { log(Double(max(freq, 0)) + 1.0) }
}

public enum DictionaryError: Error, CustomStringConvertible {
    case badMagic
    case truncated
    case notFound(String)

    public var description: String {
        switch self {
        case .badMagic: return "pinyin dictionary has an unknown format"
        case .truncated: return "pinyin dictionary is truncated"
        case .notFound(let path): return "pinyin dictionary not found: \(path)"
        }
    }
}

/// Immutable, sorted word list indexed by toneless pinyin.
///
/// Storage is a compact binary blob produced by `tools/build_dict.py`:
///   magic "EVND" | version u32 | count u32
///   repeated: keyLen u16 | key utf8 | wordLen u16 | word utf8 | freq f32
/// Entries are sorted by key (ASCII, so byte order == Swift String order).
public final class PinyinDictionary: @unchecked Sendable {
    public static let resourceName = "pinyin.bin"

    public let entries: [DictEntry]
    public let maxKeyLength: Int
    /// All syllables seen in the dictionary, permissively derived from every key.
    public let syllables: Set<String>

    public init(entries: [DictEntry]) {
        self.entries = entries.sorted { $0.key < $1.key }
        self.maxKeyLength = self.entries.reduce(0) { max($0, $1.key.count) }
        self.syllables = PinyinDictionary.deriveSyllables(from: self.entries)
    }

    /// Derives candidate syllables without a hard-coded table: a syllable is any
    /// prefix of a key that is also a complete key or a known prefix boundary.
    /// Duplicates are harmless; the segmenter only uses this to split.
    private static func deriveSyllables(from entries: [DictEntry]) -> Set<String> {
        var result = Set<String>()
        // Single-character words give us the canonical syllable set.
        for entry in entries where entry.word.count == 1 && entry.key.count <= 7 {
            result.insert(entry.key)
        }
        return result
    }

    // MARK: - Loading

    public static func load(from url: URL) throws -> PinyinDictionary {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> PinyinDictionary {
        let bytes = [UInt8](data)
        var cursor = 0

        func require(_ count: Int) throws {
            if cursor + count > bytes.count { throw DictionaryError.truncated }
        }
        func readU16() throws -> Int {
            try require(2)
            let value = Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8)
            cursor += 2
            return value
        }
        func readU32() throws -> Int {
            try require(4)
            let value = Int(bytes[cursor])
                | (Int(bytes[cursor + 1]) << 8)
                | (Int(bytes[cursor + 2]) << 16)
                | (Int(bytes[cursor + 3]) << 24)
            cursor += 4
            return value
        }

        try require(12)
        guard bytes[0] == 0x45, bytes[1] == 0x56, bytes[2] == 0x4E, bytes[3] == 0x44 else {
            throw DictionaryError.badMagic
        }
        cursor = 4
        let version = try readU32()
        guard version == 1 else { throw DictionaryError.badMagic }
        let count = try readU32()
        guard count >= 0 && count < 5_000_000 else { throw DictionaryError.truncated }

        var entries: [DictEntry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let keyLength = try readU16()
            try require(keyLength)
            let key = String(decoding: bytes[cursor..<(cursor + keyLength)], as: UTF8.self)
            cursor += keyLength

            let wordLength = try readU16()
            try require(wordLength)
            let word = String(decoding: bytes[cursor..<(cursor + wordLength)], as: UTF8.self)
            cursor += wordLength

            try require(4)
            let bits = UInt32(bytes[cursor])
                | (UInt32(bytes[cursor + 1]) << 8)
                | (UInt32(bytes[cursor + 2]) << 16)
                | (UInt32(bytes[cursor + 3]) << 24)
            cursor += 4
            let freq = Float(bitPattern: bits)

            entries.append(DictEntry(key: key, word: word, freq: freq))
        }
        return PinyinDictionary(entries: entries)
    }

    /// Looks for the dictionary in the usual places: the app bundle, the
    /// `ELEVEN_DICT` environment variable, and the source tree next to the binary.
    public static func locate() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["ELEVEN_DICT"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resource = Bundle.main.resourceURL {
            candidates.append(resource.appendingPathComponent(resourceName))
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        candidates.append(executable.appendingPathComponent("Resources/\(resourceName)"))
        candidates.append(executable.deletingLastPathComponent().appendingPathComponent("Resources/\(resourceName)"))
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/\(resourceName)"))

        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    public static func loadDefault() throws -> PinyinDictionary {
        guard let url = locate() else { throw DictionaryError.notFound("Resources/\(resourceName)") }
        return try load(from: url)
    }

    // MARK: - Lookup

    /// Index of the first entry whose key is >= `target`.
    public func lowerBound(_ target: String) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].key < target {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// All entries whose key starts with `prefix`.
    /// Keys are ASCII lowercase, so "{" sorts right after "z".
    public func prefixRange(_ prefix: String) -> Range<Int> {
        guard !prefix.isEmpty else { return 0..<entries.count }
        let lower = lowerBound(prefix)
        let upper = lowerBound(prefix + "{")
        return lower..<max(lower, upper)
    }

    /// Entries whose key is exactly `key`.
    public func exactEntries(_ key: String) -> [DictEntry] {
        let range = prefixRange(key)
        guard !range.isEmpty else { return [] }
        var result: [DictEntry] = []
        for index in range {
            let entry = entries[index]
            if entry.key == key { result.append(entry) }
        }
        return result
    }
}
