import UIKit
import CedricCore

/// Paints above the text without adding attributes or characters to storage.
final class InvisiblesOverlay: UIView {
    weak var textView: UITextView?
    var color = UIColor.clear
    private(set) var lastDrawnRange: NSRange?
    private(set) var lastGlyphCount = 0
    var tracksDrawnRange = false
    private(set) var lastGlyphPoints: [CGPoint] = []
    var tracksGlyphPoints = false
    private(set) var lastProcessedUnitCount = 0
    private(set) var displayRequests = 0
    private(set) var glyphCacheBuilds = 0
    private var textVersion = 0
    private var pendingRefresh = false
    private var lastState: State?
    private var cachedFont: UIFont?
    private var cachedColor: UIColor?
    private var glyphs: [UInt16: NSAttributedString] = [:]

    private struct State: Equatable {
        let bounds: CGRect
        let inset: UIEdgeInsets
        let padding: CGFloat
        let containerSize: CGSize
        let textVersion: Int
        let font: UIFont
        let color: UIColor
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isHidden: Bool {
        didSet {
            if oldValue != isHidden {
                lastState = nil
                if !isHidden { refresh() }
            }
        }
    }

    func textChanged() {
        textVersion &+= 1
        refresh()
    }

    func refresh() {
        guard !isHidden, let textView, !pendingRefresh, currentState(for: textView) != lastState else { return }
        pendingRefresh = true
        DispatchQueue.main.async { [weak self] in
            self?.applyRefresh()
        }
    }

    private func applyRefresh() {
        pendingRefresh = false
        guard !isHidden, let textView else { return }
        let state = currentState(for: textView)
        guard state != lastState else { return }
        lastState = state
        if frame != state.bounds { frame = state.bounds }
        if cachedFont != state.font || cachedColor != state.color {
            let attrs: [NSAttributedString.Key: Any] = [.font: state.font, .foregroundColor: state.color]
            glyphs = Dictionary(uniqueKeysWithValues: [UInt16(32), 9, 10].compactMap { unit in
                InvisibleGlyph.forUTF16(unit).map { (unit, NSAttributedString(string: $0, attributes: attrs)) }
            })
            cachedFont = state.font
            cachedColor = state.color
            glyphCacheBuilds += 1
        }
        displayRequests += 1
        setNeedsDisplay()
    }

    private func currentState(for textView: UITextView) -> State {
        let font = textView.font ?? UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        return State(bounds: textView.bounds, inset: textView.textContainerInset,
                     padding: textView.textContainer.lineFragmentPadding,
                     containerSize: textView.textContainer.size, textVersion: textVersion,
                     font: font, color: color)
    }

    override func draw(_ rect: CGRect) {
        lastDrawnRange = nil
        lastGlyphCount = 0
        lastGlyphPoints = []
        lastProcessedUnitCount = 0
        guard let tv = textView, let layout = tv.textLayoutManager,
              let manager = layout.textContentManager else { return }
        let visible = tv.bounds
        let inset = tv.textContainerInset
        let top = CGPoint(x: 0, y: max(0, visible.minY - inset.top))
        guard let start = layout.textLayoutFragment(for: top)?.rangeInElement.location
                ?? layout.textViewportLayoutController.viewportRange?.location else { return }
        let clip = rect.offsetBy(dx: visible.minX, dy: visible.minY)
        layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: inset.left, dy: inset.top)
            if frame.minY > clip.maxY { return false }
            if frame.maxY < clip.minY { return true }
            guard let paragraph = fragment.textElement as? NSTextParagraph,
                  let paragraphRange = paragraph.elementRange else { return true }
            let attributed = paragraph.attributedString
            var paragraphStart: Int?
            for line in fragment.textLineFragments {
                // TextKit's typographic bounds already include lineFragmentPadding.
                let lineOrigin = CGPoint(x: frame.minX + line.typographicBounds.minX,
                                         y: frame.minY + line.typographicBounds.minY)
                guard lineOrigin.y + line.typographicBounds.height >= clip.minY, lineOrigin.y <= clip.maxY else { continue }
                var range = NSIntersectionRange(line.characterRange, NSRange(location: 0, length: attributed.length))
                if range.length > InvisibleWindow.limit {
                    if paragraphStart == nil {
                        paragraphStart = manager.offset(from: layout.documentRange.location, to: paragraphRange.location)
                    }
                    let y = lineOrigin.y + line.typographicBounds.height / 2
                    let left = tv.closestPosition(to: CGPoint(x: clip.minX, y: y))
                    let right = tv.closestPosition(to: CGPoint(x: clip.maxX, y: y))
                    let a = left.map { tv.offset(from: tv.beginningOfDocument, to: $0) - paragraphStart! }
                    let b = right.map { tv.offset(from: tv.beginningOfDocument, to: $0) - paragraphStart! }
                    range = InvisibleWindow.range(in: range, left: a, right: b)
                }
                if self.tracksDrawnRange {
                    if paragraphStart == nil {
                        paragraphStart = manager.offset(from: layout.documentRange.location, to: paragraphRange.location)
                    }
                    let absolute = NSRange(location: paragraphStart! + range.location, length: range.length)
                    self.lastDrawnRange = self.lastDrawnRange.map { NSUnionRange($0, absolute) } ?? absolute
                    self.lastProcessedUnitCount += range.length
                }
                let units = attributed.attributedSubstring(from: range).string as NSString
                for i in range.location..<NSMaxRange(range) {
                    guard let glyph = self.glyphs[units.character(at: i - range.location)] else { continue }
                    let position = line.locationForCharacter(at: i)
                    let point = CGPoint(x: lineOrigin.x + position.x - visible.minX,
                                        y: lineOrigin.y - visible.minY)
                    guard point.x + glyph.size().width >= rect.minX, point.x <= rect.maxX else { continue }
                    glyph.draw(at: point)
                    self.lastGlyphCount += 1
                    if self.tracksGlyphPoints { self.lastGlyphPoints.append(point) }
                }
            }
            return true
        }
    }
}
