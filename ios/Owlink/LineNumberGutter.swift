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

    /// Width for `lineCount` lines in `font`, with room to breathe on the right.
    static func width(lineCount: Int, font: UIFont) -> CGFloat {
        let digits = max(2, String(max(lineCount, 1)).count)
        let sample = String(repeating: "8", count: digits) as NSString
        return ceil(sample.size(withAttributes: [.font: font]).width) + 14
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        contentMode = .redraw
        accessibilityElementsHidden = true
        accessibilityIdentifier = "editor.lineNumbers"
    }

    required init?(coder: NSCoder) { fatalError() }

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
            let s = String(row.line) as NSString
            s.draw(in: CGRect(x: 2, y: row.midY - h / 2, width: bounds.width - 8, height: h + 1), withAttributes: attrs)
        }
    }
}
