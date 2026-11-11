import AppKit
import ElevenCore

/// Small, non-activating candidate window.
///
/// A custom panel (rather than IMKCandidates) lets each candidate carry a hint
/// such as "屏幕 ×12" — the whole point of this input method.
final class CandidatePanel: NSPanel {
    var onSelect: ((Int) -> Void)?

    private let listView = CandidateListView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: CandidateListView.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        isMovable = false
        isReleasedWhenClosed = false
        contentView = listView
        listView.onSelect = { [weak self] index in self?.onSelect?(index) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(candidates: [Candidate], anchor: NSRect, showHints: Bool, selected: Int) {
        guard !candidates.isEmpty else {
            orderOut(nil)
            return
        }
        listView.update(candidates: candidates, showHints: showHints, selected: selected)
        let size = listView.preferredSize
        setContentSize(size)

        var point = anchor
        if point.width < 1 || point.height < 1 || point.origin.x.isNaN || point.origin.y.isNaN {
            point = NSRect(origin: NSEvent.mouseLocation, size: .zero)
        }

        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: point.midX, y: point.midY)) }) ?? NSScreen.main
        var origin = NSPoint(x: point.minX, y: point.minY - size.height - 6)
        if let visible = screen?.visibleFrame {
            if origin.y < visible.minY + 4 {
                origin.y = point.maxY + 6
            }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        setFrameOrigin(origin)
        orderFrontRegardless()
    }

    func select(_ index: Int) {
        listView.setSelected(index)
    }
}

private final class CandidateListView: NSView {
    static let height: CGFloat = 54

    var onSelect: ((Int) -> Void)?
    private(set) var preferredSize = NSSize(width: 240, height: CandidateListView.height)

    private var candidates: [Candidate] = []
    private var showHints = true
    private var selectedIndex = 0
    private var cells: [NSRect] = []

    private let wordFont = NSFont.systemFont(ofSize: 17, weight: .medium)
    private let hintFont = NSFont.systemFont(ofSize: 9.5, weight: .regular)
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(candidates: [Candidate], showHints: Bool, selected: Int) {
        self.candidates = candidates
        self.showHints = showHints
        self.selectedIndex = max(0, min(selected, candidates.count - 1))
        layoutCells()
        needsDisplay = true
    }

    func setSelected(_ index: Int) {
        guard !candidates.isEmpty else { return }
        selectedIndex = (index % candidates.count + candidates.count) % candidates.count
        needsDisplay = true
    }

    private func layoutCells() {
        cells.removeAll()

        var x: CGFloat = 6
        for candidate in candidates {
            let wordWidth = (candidate.text as NSString).size(withAttributes: [.font: wordFont]).width
            let hint = showHints ? (candidate.hint ?? "") : ""
            let hintWidth = hint.isEmpty ? 0 : (hint as NSString).size(withAttributes: [.font: hintFont]).width
            let width = max(48, ceil(max(wordWidth, hintWidth)) + 22)
            cells.append(NSRect(x: x, y: 5, width: width, height: CandidateListView.height - 10))
            x += width + 2
        }
        preferredSize = NSSize(width: max(120, x + 4), height: CandidateListView.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.withAlphaComponent(0.97).setFill()
        background.fill()
        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        background.lineWidth = 1
        background.stroke()

        for (index, cell) in cells.enumerated() {
            guard index < candidates.count else { break }
            let isSelected = index == selectedIndex
            let cellRect = cell.insetBy(dx: 1, dy: 1)

            if isSelected {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: cellRect, xRadius: 8, yRadius: 8).fill()
            }

            let primary: NSColor = isSelected ? .white : .labelColor
            let secondary: NSColor = isSelected ? NSColor.white.withAlphaComponent(0.72) : .tertiaryLabelColor
            let hintColor: NSColor = isSelected ? NSColor.white.withAlphaComponent(0.85) : .controlAccentColor

            let number = "\(index + 1)" as NSString
            number.draw(
                at: NSPoint(x: cellRect.minX + 8, y: cellRect.maxY - 15),
                withAttributes: [.font: numberFont, .foregroundColor: secondary]
            )

            let word = candidates[index].text as NSString
            let wordSize = word.size(withAttributes: [.font: wordFont])
            word.draw(
                at: NSPoint(x: cellRect.minX + 8, y: cellRect.minY + 13),
                withAttributes: [.font: wordFont, .foregroundColor: primary]
            )
            _ = wordSize

            if showHints, let hint = candidates[index].hint, !hint.isEmpty {
                (hint as NSString).draw(
                    at: NSPoint(x: cellRect.minX + 8, y: cellRect.minY + 3),
                    withAttributes: [.font: hintFont, .foregroundColor: hintColor]
                )
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = cells.firstIndex(where: { $0.contains(point) }) {
            onSelect?(index)
        }
    }
}
