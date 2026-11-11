import AppKit
import InputMethodKit
import ElevenCore

@objc(ElevenInputController)
final class ElevenInputController: IMKInputController {
    private var engine: PinyinEngine?
    private var buffer = ""
    private var candidates: [Candidate] = []
    private var selectedIndex = 0
    private var clientRef: AnyObject?
    private var lastRefresh = Date.distantPast
    private let panel = CandidatePanel()

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        engine = IMEShared.shared.makeEngine()
        panel.onSelect = { [weak self] index in
            guard let self = self else { return }
            guard let client = self.clientRef as? IMKTextInput else { return }
            self.commitCandidate(at: index, client: client)
        }
        Log.write("input controller created")
    }

    // MARK: - Session lifecycle

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        IMEShared.shared.syncSettings()
        // A good moment to learn what is on screen: apps usually switch before
        // the user starts typing.
        IMEShared.shared.harvester.refreshFrontmost()
    }

    override func deactivateServer(_ sender: Any!) {
        if let client = sender as? IMKTextInput {
            discardComposition(client)
        }
        engine?.resetSession()
        super.deactivateServer(sender)
    }

    override func inputControllerWillClose() {
        panel.orderOut(nil)
        super.inputControllerWillClose()
    }

    override func commitComposition(_ sender: Any!) {
        let client = (sender as? IMKTextInput) ?? (clientRef as? IMKTextInput)
        if let client = client, !buffer.isEmpty, !candidates.isEmpty {
            commitCandidate(at: selectedIndex, client: client)
        } else if let client = client {
            discardComposition(client)
        }
    }

    // MARK: - Key handling

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event = event, let client = sender as? IMKTextInput else { return false }
        clientRef = client as AnyObject
        IMEShared.shared.syncSettings()

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            if !buffer.isEmpty {
                discardComposition(client)
            }
            return false
        }

        let keyCode = event.keyCode
        let characters = (event.charactersIgnoringModifiers ?? "").lowercased()

        // Start a composition only on a plain latin letter.
        if buffer.isEmpty {
            guard characters.count == 1,
                  let scalar = characters.unicodeScalars.first,
                  (97...122).contains(scalar.value)
            else { return false }
            buffer = characters
            selectedIndex = 0
            updateComposition(client)
            return true
        }

        switch keyCode {
        case 53: // escape
            discardComposition(client)
            return true

        case 51, 117: // delete / forward delete
            if buffer.count <= 1 {
                discardComposition(client)
            } else {
                buffer.removeLast()
                selectedIndex = 0
                updateComposition(client)
            }
            return true

        case 36, 76, 49: // return, keypad enter, space
            commitSelected(client)
            return true

        case 126: // up
            moveSelection(by: -1)
            return true
        case 125: // down
            moveSelection(by: 1)
            return true
        case 123: // left
            moveSelection(by: -1)
            return true
        case 124: // right
            moveSelection(by: 1)
            return true

        default:
            break
        }

        if characters.count == 1, let digit = Int(characters), (1...9).contains(digit) {
            commitCandidate(at: digit - 1, client: client)
            return true
        }

        if characters.count == 1,
           let scalar = characters.unicodeScalars.first,
           (97...122).contains(scalar.value) {
            if buffer.count < 32 { buffer += characters }
            selectedIndex = 0
            updateComposition(client)
            return true
        }

        if characters == "'" {
            if buffer.count < 32 { buffer += characters }
            selectedIndex = 0
            updateComposition(client)
            return true
        }

        // Punctuation and anything else: accept the highlighted candidate, then
        // let the application handle the key normally.
        commitSelected(client)
        return false
    }

    // MARK: - Composition

    private func updateComposition(_ client: IMKTextInput) {
        guard !buffer.isEmpty else {
            discardComposition(client)
            return
        }

        let settings = IMEShared.shared.settings
        let snapshot = IMEShared.shared.harvester.snapshot()
        let stale = snapshot.isEmpty || Date().timeIntervalSince(snapshot.capturedAt) > 8
        if Date().timeIntervalSince(lastRefresh) > 0.8 {
            lastRefresh = Date()
            // Wait on the very first keystroke so context is already applied;
            // later keystrokes reuse the cached harvest.
            IMEShared.shared.harvester.refreshFrontmost(wait: buffer.count == 1 && stale)
        }

        candidates = engine?.candidates(for: buffer, limit: settings.candidateLimit) ?? []
        selectedIndex = 0

        let marked = NSAttributedString(
            string: buffer,
            attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: NSColor.tertiaryLabelColor,
            ]
        )
        client.setMarkedText(
            marked,
            selectionRange: NSRange(location: (buffer as NSString).length, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )

        if candidates.isEmpty {
            panel.orderOut(nil)
        } else {
            panel.show(
                candidates: candidates,
                anchor: caretRect(client),
                showHints: settings.showContextHints,
                selected: 0
            )
        }
    }

    private func moveSelection(by delta: Int) {
        guard !candidates.isEmpty else { return }
        let count = candidates.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
        panel.select(selectedIndex)
    }

    private func commitSelected(_ client: IMKTextInput) {
        if !candidates.isEmpty {
            commitCandidate(at: selectedIndex, client: client)
        } else {
            discardComposition(client)
        }
    }

    private func commitCandidate(at index: Int, client: IMKTextInput) {
        guard index >= 0, index < candidates.count else {
            discardComposition(client)
            return
        }
        let text = candidates[index].text
        client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        engine?.recordCommit(text)
        IMEShared.shared.harvester.appendCommitted(text)

        buffer = ""
        candidates = []
        selectedIndex = 0
        panel.orderOut(nil)
    }

    private func discardComposition(_ client: IMKTextInput) {
        buffer = ""
        candidates = []
        selectedIndex = 0
        panel.orderOut(nil)
        client.setMarkedText(
            "",
            selectionRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: NSNotFound)
        )
    }

    private func caretRect(_ client: IMKTextInput) -> NSRect {
        var actual = NSRange(location: 0, length: 0)
        let selected = client.selectedRange()
        let location = selected.location == NSNotFound ? 0 : selected.location
        let rect = client.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: &actual)
        if rect.isNull || rect.isInfinite || rect.width.isNaN { return .zero }
        return rect
    }

    // MARK: - Menu

    override func menu() -> NSMenu! {
        let menu = NSMenu()
        let item = NSMenuItem(title: "拾文输入法设置…", action: #selector(showSettings), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func showSettings() {
        PreferencesWindowController.shared.show()
    }
}
