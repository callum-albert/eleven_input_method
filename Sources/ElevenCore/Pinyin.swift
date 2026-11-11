import Foundation

/// Pinyin string helpers shared by the engine and the dictionary loader.
public enum Pinyin {
    /// Keeps only ASCII letters, lowercased. Apostrophes and spaces are treated as
    /// syllable separators and dropped: "Gou'Jian" -> "goujian".
    /// `ü` (and the `v` convention) become `v`.
    public static func normalize(_ raw: String) -> String {
        var out = String()
        out.reserveCapacity(raw.count)
        for scalar in raw.lowercased().unicodeScalars {
            if scalar == "ü" {
                out.append("v")
            } else if scalar.value >= 97 && scalar.value <= 122 {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Splits a dictionary key into syllables using the syllable set embedded
    /// in the dictionary itself (see `PinyinDictionary.syllables`).
    public static func split(_ key: String, syllables: Set<String>) -> [String]? {
        guard !key.isEmpty else { return [] }
        var result: [String] = []
        var index = key.startIndex
        while index < key.endIndex {
            var matched: String?
            var end = index
            while end < key.endIndex {
                end = key.index(after: end)
                let candidate = String(key[index..<end])
                if candidate.count > 7 { break }
                if syllables.contains(candidate) {
                    matched = candidate
                    break
                }
            }
            guard let syllable = matched else { return nil }
            result.append(syllable)
            index = key.index(index, offsetBy: syllable.count)
        }
        return result
    }
}
