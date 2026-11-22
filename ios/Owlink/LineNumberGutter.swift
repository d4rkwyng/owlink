import UIKit

/// Line numbers for the visible lines of the editor. Drawn beside the text,
/// not inside the text view, so they stay put while the text scrolls.
/// A jump can also turn it on for one tab without changing the setting.
final class LineNumberGutter: UIView {
    struct Row {
        var line: Int
        var midY: CGFloat
    }

    var rows: [Row] = []
    /// 1-based line to draw stronger, the one just jumped to.
    var highlight: Int?
    var font: UIFont = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    var numberColor: UIColor = .secondaryLabel
    var highlightColor: UIColor = .label
    var bandColor: UIColor = .clear
    /// 1-based bookmarked lines, drawn as a rounded tab at the left edge.
    var bookmarked: Set<Int> = []
    var bookmarkColor: UIColor = .tintColor
    /// A tap on a row: its 1-based line (toggles its bookmark).
    var onTapLine: ((Int) -> Void)?

    /// Width for `lineCount` lines in `font`, with room to breathe on the right.
    static func width(lineCount: Int, font: UIFont) -> CGFloat {
        let digits = max(2, String(max(lineCount, 1)).count)
        let sample = String(repeating: "8", count: digits) as NSString
        return ceil(sample.size(withAttributes: [.font: font]).width) + 14
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        // On for the tap that toggles a bookmark; VoiceOver uses the menu.
        isUserInteractionEnabled = true
        backgroundColor = .clear
        contentMode = .redraw
        accessibilityElementsHidden = true
        accessibilityIdentifier = "editor.lineNumbers"
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The 1-based line of the row nearest `point` (in the gutter's
    /// coordinates), nil with no rows shown.
    func line(at point: CGPoint) -> Int? {
        rows.min { abs($0.midY - point.y) < abs($1.midY - point.y) }?.line
    }

    /// The 1-based lines shown with a bookmark marker (for tests).
    var markedRows: [Int] { rows.map(\.line).filter { bookmarked.contains($0) } }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard tap.state == .ended, let line = line(at: tap.location(in: self)) else { return }
        onTapLine?(line)
    }

    override func draw(_ rect: CGRect) {
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        for row in rows {
            let marked = row.line == highlight
            let h = font.lineHeight
            if marked {
                bandColor.setFill()
                UIBezierPath(rect: CGRect(x: 0, y: row.midY - h / 2 - 1, width: bounds.width, height: h + 2)).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: marked ? highlightColor : numberColor,
                .paragraphStyle: para,
            ]
            if bookmarked.contains(row.line) {
                // The Mac's marker: a rounded tab at the left edge.
                let tall = max(6, min(bounds.height, h))
                bookmarkColor.setFill()
                UIBezierPath(roundedRect: CGRect(x: 2, y: row.midY - tall / 2 + 1, width: 5, height: tall - 2), cornerRadius: 2).fill()
            }
            let s = String(row.line) as NSString
            s.draw(in: CGRect(x: 2, y: row.midY - h / 2, width: bounds.width - 8, height: h + 1), withAttributes: attrs)
        }
    }
}
