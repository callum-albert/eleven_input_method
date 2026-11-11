import Foundation

public struct Candidate: Sendable, Equatable {
    public let text: String
    /// The pinyin key that produced it.
    public let key: String
    public let score: Double
    /// 0 = word exactly matching the input, 1 = prefix match, 2 = phrase, 3 = raw.
    public let tier: Int
    public let hint: String?

    public init(text: String, key: String, score: Double, tier: Int, hint: String?) {
        self.text = text
        self.key = key
        self.score = score
        self.tier = tier
        self.hint = hint
    }
}

/// Pinyin -> Hanzi candidate generation and ranking.
///
/// Ranking order is tiered (exact word > partial word > composed phrase), and
/// within a tier it is `unigram log-frequency + screen/document context + learned
/// personal frequency`. That is what makes 构件 jump ahead of 构建 when the
/// surrounding text keeps saying 构件.
public final class PinyinEngine: @unchecked Sendable {
    public let dictionary: PinyinDictionary
    public var weights: RankingWeights

    private let learning: LearningStore?
    private let contextProvider: (() -> ContextSnapshot)?
    private let lock = NSLock()
    private var lastCommittedWord = ""

    public init(
        dictionary: PinyinDictionary,
        learning: LearningStore? = nil,
        weights: RankingWeights = RankingWeights(),
        contextProvider: (() -> ContextSnapshot)? = nil
    ) {
        self.dictionary = dictionary
        self.learning = learning
        self.weights = weights
        self.contextProvider = contextProvider
    }

    // MARK: - Public API

    public func candidates(for rawInput: String, limit: Int = 9) -> [Candidate] {
        let input = Pinyin.normalize(rawInput)
        guard !input.isEmpty else { return [] }

        let snapshot = contextProvider?() ?? ContextSnapshot()
        let context = ContextModel(snapshot: snapshot, weights: weights)
        let previousCharacter = snapshot.beforeCursor.last

        var pool = wordCandidates(for: input)
        if pool.filter({ $0.tier == 0 }).isEmpty {
            pool.append(contentsOf: phraseCandidates(for: input))
        }

        // Cheap ordering first, context scoring only for the shortlist.
        pool.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            return lhs.baseScore > rhs.baseScore
        }
        let shortlist = pool.prefix(64)

        let previousWord: String = {
            lock.lock()
            defer { lock.unlock() }
            return lastCommittedWord
        }()

        var byText: [String: Candidate] = [:]
        for item in shortlist {
            let text = item.text
            let evaluation = context.evaluate(word: text, previousCharacter: previousCharacter)
            let learned = learning?.boost(word: text, previous: previousWord) ?? 0
            let score = item.baseScore + evaluation.score + learned

            var hints = evaluation.hints
            if learned > 0.7 { hints.append("常用") }
            let hint = hints.first

            let candidate = Candidate(
                text: text,
                key: input,
                score: score,
                tier: item.tier,
                hint: hint
            )
            if let existing = byText[text] {
                if score > existing.score {
                    byText[text] = candidate
                }
            } else {
                byText[text] = candidate
            }
        }

        var results = Array(byText.values)
        results.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.text.count < rhs.text.count
        }

        if results.isEmpty {
            return [Candidate(text: input, key: input, score: 0, tier: 3, hint: "原样")]
        }
        return Array(results.prefix(limit))
    }

    /// Called when the user commits text. Feeds local personalization only.
    public func recordCommit(_ text: String) {
        guard !text.isEmpty, !text.contains(where: { $0.isLetter && $0.isASCII }) else { return }
        lock.lock()
        let previous = lastCommittedWord
        lastCommittedWord = text
        lock.unlock()
        learning?.record(word: text, previous: previous.isEmpty ? nil : previous)
    }

    public func resetSession() {
        lock.lock()
        lastCommittedWord = ""
        lock.unlock()
    }

    // MARK: - Word candidates

    private struct PoolItem {
        let text: String
        let tier: Int
        let baseScore: Double
    }

    private func wordCandidates(for input: String) -> [PoolItem] {
        let range = dictionary.prefixRange(input)
        guard !range.isEmpty else { return [] }

        var result: [PoolItem] = []
        result.reserveCapacity(min(range.count, 512))

        var scanned = 0
        for index in range {
            let entry = dictionary.entries[index]
            let extra = entry.key.count - input.count
            guard extra >= 0, extra <= 8 else { continue }
            scanned += 1
            if scanned > 20_000 { break }

            let tier = extra == 0 ? 0 : 2
            let base = entry.logFreq
                + (tier == 0 ? weights.exactBonus : 0)
                - Double(extra) * weights.partialPenaltyPerChar
            result.append(PoolItem(text: entry.word, tier: tier, baseScore: base))
        }
        return result
    }

    // MARK: - Phrase candidates (word lattice + beam search)

    private func phraseCandidates(for input: String) -> [PoolItem] {
        let characters = Array(input)
        let count = characters.count
        guard count > 1 else { return [] }

        // Precompute the lattice once: position -> [(end, entry)].
        var edges: [[(end: Int, entry: DictEntry)]] = Array(repeating: [], count: count)
        for position in 0..<count {
            let maxLength = min(dictionary.maxKeyLength, 24, count - position)
            guard maxLength >= 1 else { continue }
            for length in 1...maxLength {
                let key = String(characters[position..<(position + length)])
                let matches = dictionary.exactEntries(key)
                guard !matches.isEmpty else { continue }
                for entry in matches.sorted(by: { $0.freq > $1.freq }).prefix(2) {
                    edges[position].append((position + length, entry))
                }
            }
        }

        // beams[i] = best partial segmentations of characters[0..<i]
        var beams: [[(score: Double, words: [String])]] = Array(repeating: [], count: count + 1)
        beams[0] = [(0, [])]
        let beamWidth = 40

        for position in 0..<count {
            if beams[position].isEmpty { continue }
            if beams[position].count > beamWidth {
                beams[position].sort { $0.score > $1.score }
                beams[position] = Array(beams[position].prefix(beamWidth))
            }

            for state in beams[position] {
                for edge in edges[position] {
                    let entry = edge.entry
                    let isFirst = state.words.isEmpty
                    let boundaryPenalty = isFirst ? 0 : weights.compositionWordPenalty
                    let lengthBonus = weights.compositionLengthBonus * Double(max(0, entry.word.count - 1))
                    let singlePenalty = entry.word.count == 1 ? weights.compositionSingleCharPenalty : 0
                    var words = state.words
                    words.append(entry.word)
                    let score = state.score + entry.logFreq + lengthBonus - boundaryPenalty - singlePenalty
                    beams[edge.end].append((score, words))
                }
            }
        }

        var results: [PoolItem] = []
        var seen = Set<String>()
        for state in beams[count].sorted(by: { $0.score > $1.score }).prefix(16) {
            let text = state.words.joined()
            guard !text.isEmpty, !seen.contains(text) else { continue }
            seen.insert(text)
            results.append(PoolItem(text: text, tier: 1, baseScore: state.score))
        }
        return results
    }
}
