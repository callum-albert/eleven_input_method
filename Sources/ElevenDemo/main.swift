import AppKit
import Carbon
import ElevenCore

// Standalone demo of the ranking engine. It does not need to be registered as a
// system input method: ⌃⌥Space opens a small input board, reads the frontmost
// window once, and pastes the chosen text back into it.

final class DemoAppDelegate: NSObject, NSApplicationDelegate {
    private var window: DemoWindow!
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = DemoWindow()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData = userData else { return noErr }
                let delegate = Unmanaged<DemoAppDelegate>.fromOpaque(userData).takeUnretainedValue()
                delegate.toggle()
                return noErr
            },
            1,
            &eventType,
            pointer,
            nil
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x45564E54), id: 1) // 'EVNT'
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func toggle() {
        window.toggle()
    }
}

// Headless check used by the build script: verifies that the bundled
// dictionary can be loaded from inside the .app.
if CommandLine.arguments.contains("--selftest") {
    let dictionary = try PinyinDictionary.loadDefault()
    var snapshot = ContextSnapshot()
    snapshot.windowText = String(repeating: "构件受力分析。", count: 6)
    snapshot.beforeCursor = snapshot.windowText
    snapshot.sources = [.accessibility]
    snapshot.capturedAt = Date()
    let engine = PinyinEngine(dictionary: dictionary, contextProvider: { snapshot })
    print("entries: \(dictionary.entries.count)")
    print("goujian: " + engine.candidates(for: "goujian", limit: 4).map(\.text).joined(separator: " / "))
    print("woaibeijing: " + engine.candidates(for: "woaibeijing", limit: 3).map(\.text).joined(separator: " / "))
    exit(0)
}

let application = NSApplication.shared
let delegate = DemoAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
