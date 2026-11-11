import Foundation
import ElevenCore

/// Command line harness for the ranking engine. Useful for tuning and for
/// demoing the context behaviour without installing the input method.
///
///   eleven-probe goujian --context-file screen.txt
///   eleven-probe goujian --context "构件构件构件" --repeat 4
///   eleven-probe woaibeijing --show-scores
///   eleven-probe goujian --ax            # live frontmost window

struct Options {
    var input = ""
    var context = ""
    var contextFile: String?
    var repeatCount = 1
    var limit = 9
    var showScores = false
    var useAX = false
    var useOCR = false
    var bench = 0
}

func parseArguments() -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        func next() -> String? {
            guard index + 1 < arguments.count else { return nil }
            index += 1
            return arguments[index]
        }
        switch argument {
        case "--context":
            options.context = next() ?? ""
        case "--context-file":
            options.contextFile = next()
        case "--repeat":
            options.repeatCount = Int(next() ?? "") ?? 1
        case "--limit":
            options.limit = max(1, min(20, Int(next() ?? "") ?? 9))
        case "--show-scores":
            options.showScores = true
        case "--ax":
            options.useAX = true
        case "--ocr":
            options.useOCR = true
        case "--bench":
            options.bench = Int(next() ?? "") ?? 1
        case "-h", "--help":
            print("usage: eleven-probe <pinyin> [--context TEXT] [--context-file PATH] [--repeat N] [--limit N] [--show-scores] [--ax] [--ocr] [--bench N]")
            exit(0)
        default:
            if options.input.isEmpty {
                options.input = argument
            }
        }
        index += 1
    }
    return options
}

let options = parseArguments()
guard !options.input.isEmpty else {
    FileHandle.standardError.write(Data("usage: eleven-probe <pinyin> [--context TEXT] [--context-file PATH]\n".utf8))
    exit(2)
}

let dictionary: PinyinDictionary
do {
    dictionary = try PinyinDictionary.loadDefault()
} catch {
    FileHandle.standardError.write(Data("cannot load dictionary: \(error)\nRun `python3 tools/build_dict.py` first.\n".utf8))
    exit(1)
}

var screenText = options.context
if let path = options.contextFile {
    screenText += "\n" + ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
}
if options.repeatCount > 1, !screenText.isEmpty {
    screenText = Array(repeating: screenText, count: options.repeatCount).joined(separator: "\n")
}

var snapshot = ContextSnapshot()
snapshot.windowText = screenText
snapshot.beforeCursor = screenText
snapshot.committed = screenText
snapshot.sources = [.accessibility, .committed]
snapshot.capturedAt = Date()

if options.useAX || options.useOCR {
    let harvester = ContextHarvester()
    harvester.enableAccessibility = true
    harvester.enableOCR = options.useOCR
    harvester.refreshFrontmost(force: true)
    // Give the background harvest a moment to land.
    Thread.sleep(forTimeInterval: options.useOCR ? 2.5 : 0.2)
    snapshot = harvester.snapshot()
    print("context: \(snapshot.beforeCursor.count) chars before cursor, \(snapshot.windowText.count) in window [\(harvester.lastSummary)]")
}

let engine = PinyinEngine(dictionary: dictionary, contextProvider: { snapshot })

if options.bench > 0 {
    let started = Date()
    var last: [Candidate] = []
    for _ in 0..<options.bench {
        last = engine.candidates(for: options.input, limit: options.limit)
    }
    let elapsed = Date().timeIntervalSince(started) / Double(options.bench)
    print(String(format: "%.2f ms per query, %d candidates", elapsed * 1000, last.count))
}

let candidates = engine.candidates(for: options.input, limit: options.limit)
print("input: \(options.input)  →  \(candidates.count) candidates")
for (index, candidate) in candidates.enumerated() {
    var line = String(format: "%2d. %@", index + 1, candidate.text)
    if let hint = candidate.hint {
        line += "   [\(hint)]"
    }
    if options.showScores {
        line += String(format: "   tier=%d score=%.2f", candidate.tier, candidate.score)
    }
    print(line)
}
