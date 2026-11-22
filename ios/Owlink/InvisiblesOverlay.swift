import UIKit
import CedricCore

/// Paints above the text without adding attributes or characters to storage.
final class InvisiblesOverlay: UIView {
    weak var textView: UITextView?
    var color = UIColor.clear
    private(set) var lastDrawnRange: NSRange?
    private(set) var lastGlyphCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func refresh() {
        guard !isHidden, let textView else { return }
        frame = textView.bounds
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        lastDrawnRange = nil
        lastGlyphCount = 0
        guard let tv = textView, let layout = tv.textLayoutManager,
              let manager = layout.textContentManager else { return }
        let visible = tv.bounds
        let inset = tv.textContainerInset
        let top = CGPoint(x: 0, y: max(0, visible.minY - inset.top))
        guard let start = layout.textLayoutFragment(for: top)?.rangeInElement.location
                ?? layout.textViewportLayoutController.viewportRange?.location else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: tv.font ?? UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                                     .foregroundColor: color]
        let glyphs = Dictionary(uniqueKeysWithValues: [UInt16(32), 9, 10].compactMap { unit in
            InvisibleGlyph.forUTF16(unit).map { (unit, NSAttributedString(string: $0, attributes: attrs)) }
        })
        let clip = rect.offsetBy(dx: visible.minX, dy: visible.minY)
        layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: inset.left, dy: inset.top)
            if frame.minY > clip.maxY { return false }
            if frame.maxY < clip.minY { return true }
            guard let paragraph = fragment.textElement as? NSTextParagraph,
                  let paragraphRange = paragraph.elementRange else { return true }
            let units = paragraph.attributedString.string as NSString
            let paragraphStart = manager.offset(from: layout.documentRange.location, to: paragraphRange.location)
            for line in fragment.textLineFragments {
                let lineOrigin = CGPoint(x: frame.minX + line.typographicBounds.minX,
                                         y: frame.minY + line.typographicBounds.minY)
                guard lineOrigin.y + line.typographicBounds.height >= clip.minY, lineOrigin.y <= clip.maxY else { continue }
                var range = NSIntersectionRange(line.characterRange, NSRange(location: 0, length: units.length))
                if range.length > 4096,
                   let left = tv.closestPosition(to: CGPoint(x: clip.minX, y: lineOrigin.y + line.typographicBounds.height / 2)),
                   let right = tv.closestPosition(to: CGPoint(x: clip.maxX, y: lineOrigin.y + line.typographicBounds.height / 2)) {
                    let a = tv.offset(from: tv.beginningOfDocument, to: left) - paragraphStart
                    let b = tv.offset(from: tv.beginningOfDocument, to: right) - paragraphStart
                    let start = max(range.location, min(a, b) - 1)
                    let end = min(NSMaxRange(range), max(a, b) + 1)
                    if end >= start { range = NSRange(location: start, length: end - start) }
                }
                let absolute = NSRange(location: paragraphStart + range.location, length: range.length)
                self.lastDrawnRange = self.lastDrawnRange.map { NSUnionRange($0, absolute) } ?? absolute
                for i in range.location..<NSMaxRange(range) {
                    guard let glyph = glyphs[units.character(at: i)] else { continue }
                    let position = line.locationForCharacter(at: i)
                    let point = CGPoint(x: lineOrigin.x + position.x - visible.minX,
                                        y: lineOrigin.y - visible.minY)
                    guard point.x + glyph.size().width >= rect.minX, point.x <= rect.maxX else { continue }
                    glyph.draw(at: point)
                    self.lastGlyphCount += 1
                }
            }
            return true
        }
    }
}
