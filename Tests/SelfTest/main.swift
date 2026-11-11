import Foundation
import ElevenCore

/// Small self-test harness. Command Line Tools does not ship XCTest, so this is
/// an executable test runner: `swift run ElevenSelfTest`.

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("  ✗ \(message)  (line \(line))")
    }
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String, line: Int = #line) {
    checks += 1
    if lhs != rhs {
        failures += 1
        print("  ✗ \(message): expected \(rhs), got \(lhs)  (line \(line))")
    }
}

func section(_ name: String) { print("• \(name)") }

// MARK: - Pinyin

section("Pinyin normalization")
expectEqual(Pinyin.normalize("Gou'Jian"), "goujian", "apostrophes and case")
expectEqual(Pinyin.normalize("nv er"), "nver", "spaces")
expectEqual(Pinyin.normalize("lü"), "lv", "ü -> v")
expectEqual(Pinyin.normalize("  ...nǐ  "), "n", "ignore tone marks and punctuation")

// MARK: - Dictionary

section("Dictionary lookup")

let dictionary = PinyinDictionary(entries: [
    DictEntry(key: "goujian", word: "构建", freq: 600),
    DictEntry(key: "goujian", word: "构件", freq: 300),
    DictEntry(key: "goujian", word: "勾践", freq: 10),
    DictEntry(key: "gouqi", word: "枸杞", freq: 100),
    DictEntry(key: "gou", word: "够", freq: 3000),
    DictEntry(key: "jian", word: "件", freq: 2000),
    DictEntry(key: "wo", word: "我", freq: 50_000),
    DictEntry(key: "ai", word: "爱", freq: 20_000),
    DictEntry(key: "ni", word: "你", freq: 40_000),
    DictEntry(key: "beijing", word: "北京", freq: 9_000),
    DictEntry(key: "bei", word: "被", freq: 15_000),
    DictEntry(key: "jing", word: "经", freq: 12_000),
])

expectEqual(dictionary.prefixRange("goujian").count, 3, "exact range")
expectEqual(dictionary.exactEntries("goujian").count, 3, "exact entries")
expectEqual(dictionary.prefixRange("gouj").count, 3, "prefix range")
expectEqual(dictionary.prefixRange("gou").count, 5, "short prefix range")
expect(dictionary.prefixRange("zzz").isEmpty, "unknown prefix is empty")
expectEqual(dictionary.maxKeyLength, 7, "max key length")

// Binary roundtrip
do {
    var binary = Data([0x45, 0x56, 0x4E, 0x44])
    func u32(_ value: Int) { var v = UInt32(value).littleEndian; withUnsafeBytes(of: &v) { binary.append(contentsOf: $0) } }
    func u16(_ value: Int) { var v = UInt16(value).littleEndian; withUnsafeBytes(of: &v) { binary.append(contentsOf: $0) } }
    u32(1); u32(1)
    let key = Array("goujian".utf8), word = Array("构件".utf8)
    u16(key.count); binary.append(contentsOf: key)
    u16(word.count); binary.append(contentsOf: word)
    var bits = Float(42.5).bitPattern.littleEndian
    withUnsafeBytes(of: &bits) { binary.append(contentsOf: $0) }

    let parsed = try PinyinDictionary.parse(binary)
    expectEqual(parsed.entries.count, 1, "binary entry count")
    expectEqual(parsed.exactEntries("goujian").first?.word, "构件", "binary word")
    expectEqual(parsed.exactEntries("goujian").first?.freq ?? 0, 42.5, "binary frequency")
} catch {
    expect(false, "binary parse threw \(error)")
}

expect((try? PinyinDictionary.parse(Data("NOPE".utf8))) == nil, "bad magic rejected")

// MARK: - Engine

func makeEngine(context: String = "", before: String = "", learning: LearningStore? = nil) -> PinyinEngine {
    var snapshot = ContextSnapshot()
    snapshot.windowText = context
    snapshot.beforeCursor = before
    snapshot.committed = context
    snapshot.sources = [.accessibility]
    snapshot.capturedAt = Date()
    return PinyinEngine(dictionary: dictionary, learning: learning, contextProvider: { snapshot })
}

section("Ranking")
expectEqual(makeEngine().candidates(for: "goujian").first?.text, "构建", "frequency order")

let screenText = String(repeating: "构件受力分析。", count: 8) + "构建流程。"
let flipped = makeEngine(context: screenText).candidates(for: "goujian")
expectEqual(flipped.first?.text, "构件", "screen context flips the ambiguous word")
expectEqual(flipped.first?.hint, "屏幕 ×8", "context hint")

expectEqual(makeEngine(before: "这个构件的截面").candidates(for: "goujian").first?.text, "构件", "before-cursor context")

expectEqual(makeEngine().candidates(for: "woaibeijing").first?.text, "我爱北京", "phrase composition")
expectEqual(makeEngine().candidates(for: "goujian").first?.tier, 0, "exact word tier")
expectEqual(makeEngine().candidates(for: "zzzz").first?.text, "zzzz", "raw fallback")
expectEqual(makeEngine(context: "构件").candidates(for: "goujian").count > 0, true, "non-empty candidates")
expectEqual(makeEngine().candidates(for: "goujian").first?.hint, nil, "no hint without context")

section("Partial input")
let partial = makeEngine().candidates(for: "gouj")
expect(partial.contains(where: { $0.text == "构建" }), "partial input completes 构建")
expect(partial.contains(where: { $0.text == "构件" }), "partial input completes 构件")
expectEqual(partial.first?.tier, 2, "partial candidates use prefix tier")

section("Learning")
do {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("learning-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let learning = LearningStore(url: url)
    let engine = PinyinEngine(dictionary: dictionary, learning: learning)
    for _ in 0..<6 { engine.recordCommit("构件") }
    expectEqual(engine.candidates(for: "goujian").first?.text, "构件", "learned word is promoted")
    expect(learning.isKnown(word: "构件"), "word recorded")
}

section("Context store")
do {
    let store = ContextStore()
    store.update(before: "构件", window: "构建", appName: "Test", sources: [.accessibility])
    expectEqual(store.snapshot().windowText, "构建", "fresh snapshot")
    expectEqual(store.snapshot(maxAge: -1).windowText, "", "stale snapshot drops screen text")
    store.appendCommitted("构件")
    expect(store.snapshot().committed.contains("构件"), "committed text retained")
}

// MARK: - Summary

print("")
if failures == 0 {
    print("all \(checks) checks passed")
    exit(0)
} else {
    print("\(failures) of \(checks) checks failed")
    exit(1)
}
