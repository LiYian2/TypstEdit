import AppKit

/// The ruler shares the editor's clip view. It has no document or independent scroll offset.
final class LineNumberRulerView: NSRulerView {
    var errors: Set<Int> = [] { didSet { needsDisplay = true } }
    private(set) var lineStarts = [0]
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    override var isFlipped: Bool { true }
    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = 48
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateLineStarts(_ text: String) {
        let string = text as NSString
        lineStarts = [0]
        var offset = 0
        while offset < string.length {
            let end = NSMaxRange(string.lineRange(for: NSRange(location: offset, length: 0)))
            guard end > offset else { break }
            if end < string.length || (end == string.length && [10, 13].contains(string.character(at: end - 1))) {
                lineStarts.append(end)
            }
            offset = end
        }
        refreshThickness()
    }

    /// editedRange is in the new text; the old range ends at newEnd - changeInLength.
    /// Rescan neighboring logical lines, including both sides of a possible CRLF join.
    func applyEdit(in text: NSString, editedRange: NSRange, changeInLength delta: Int) {
        let oldEnd = NSMaxRange(editedRange) - delta
        func upperBound(_ offset: Int) -> Int {
            var low = 0, high = lineStarts.count
            while low < high {
                let middle = (low + high) / 2
                if lineStarts[middle] <= offset { low = middle + 1 } else { high = middle }
            }
            return low
        }
        let first = max(0, upperBound(editedRange.location) - 2)
        let last = min(lineStarts.count, upperBound(oldEnd) + 1)
        let limit = last < lineStarts.count ? lineStarts[last] + delta : text.length
        var replacement = [lineStarts[first]]
        var offset = replacement[0]
        while offset < limit {
            let end = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
            guard end > offset else { break }
            if end < limit || (last == lineStarts.count && end == text.length && [10, 13].contains(text.character(at: end - 1))) {
                replacement.append(end)
            }
            offset = end
        }
        // Shift the cached suffix without bridging/scanning all the source characters.
        if last < lineStarts.count {
            for index in last..<lineStarts.count { lineStarts[index] += delta }
        }
        lineStarts.replaceSubrange(first..<last, with: replacement)
        refreshThickness()
    }

    private func refreshThickness() {
        let thickness = max(48, CGFloat(String(lineStarts.count).count) * 8 + 20)
        if ruleThickness != thickness { ruleThickness = thickness }
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) { scrollView?.scrollWheel(with: event) }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let view = clientView as? NSTextView, let layout = view.layoutManager,
              let container = view.textContainer else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSColor(white: 0, alpha: 0.15).setFill()
        bounds.fill()
        let visible = view.visibleRect.offsetBy(dx: -view.textContainerOrigin.x, dy: -view.textContainerOrigin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // Binary search cached UTF-16 line offsets; only lay out visible logical lines.
        var low = 0
        var high = lineStarts.count
        while low < high {
            let middle = (low + high) / 2
            if lineStarts[middle] < characters.location { low = middle + 1 } else { high = middle }
        }
        var index = max(0, low - 1)
        while index < lineStarts.count {
            let start = lineStarts[index]
            if start > NSMaxRange(characters) { break }
            let fragment: NSRect
            if start < (view.string as NSString).length {
                let glyph = layout.glyphIndexForCharacter(at: start)
                fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            } else {
                fragment = layout.extraLineFragmentRect
            }
            let origin = convert(NSPoint(x: 0, y: fragment.minY + view.textContainerOrigin.y), from: view)
            let label = String(index + 1) as NSString
            let size = label.size(withAttributes: [.font: font])
            let y = origin.y + max(0, (fragment.height - size.height) / 2)
            if errors.contains(index + 1) {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 4, y: y + 4, width: 6, height: 6)).fill()
            }
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: y),
                       withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
            index += 1
        }
    }
}
