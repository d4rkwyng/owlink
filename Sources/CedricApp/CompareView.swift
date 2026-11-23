import AppKit
import CedricCore

/// File › Compare › Compare With…: two tabs side by side, line by line (LineDiff),
/// read-only. Opens as its own tab next to the left document. The text is
/// a snapshot taken when the comparison was made.
@MainActor
final class CompareWindowController: NSWindowController, NSWindowDelegate {
    let diffView: DiffView
    var onClose: ((CompareWindowController) -> Void)?

    init(leftName: String, leftText: String, rightName: String, rightText: String, palette: EditorPalette) {
        let a = LineDiff.lines(leftText), b = LineDiff.lines(rightText)
        let rows = LineDiff.rows(LineDiff.diff(a, b))
        diffView = DiffView(left: a, right: b, rows: rows, palette: palette)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "CedricEditor"
        window.isRestorable = false
        window.title = String(localized: "\(leftName) ↔ \(rightName)")
        let counts = Dictionary(grouping: rows, by: \.kind).mapValues(\.count)
        window.subtitle = String(localized: "\(counts[.added] ?? 0) added, \(counts[.removed] ?? 0) removed, \(counts[.changed] ?? 0) changed")
        super.init(window: window)
        window.delegate = self

        let header = DiffHeader(left: leftName, right: rightName, palette: palette)
        let scroll = NSScrollView()
        scroll.documentView = diffView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(hex: palette.background)
        diffView.autoresizingMask = [.width]
        let stack = NSStackView(views: [header, scroll])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        window.contentView = stack
        window.appearance = palette.isDark ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
        diffView.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: diffView.contentHeight)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) { onClose?(self) }

    /// Scrolls to the next or previous difference.
    @objc func nextDifference(_ sender: Any?) { diffView.jumpToDifference(forward: true) }
    @objc func previousDifference(_ sender: Any?) { diffView.jumpToDifference(forward: false) }
}

/// Colours for the diff, mixed from the theme's background so every theme
/// gets a matching set.
struct DiffColors {
    let background, foreground, number, filler, added, removed, changed, addedStrong, removedStrong: NSColor

    init(_ p: EditorPalette) {
        func mix(_ hex: UInt32, _ amount: CGFloat) -> NSColor {
            NSColor(hex: p.background).blended(withFraction: amount, of: NSColor(hex: hex)) ?? NSColor(hex: hex)
        }
        let a: CGFloat = p.isDark ? 0.22 : 0.16
        background = NSColor(hex: p.background)
        foreground = NSColor(hex: p.foreground)
        number = NSColor(hex: p.gutterForeground)
        filler = NSColor(hex: p.gutterBackground)
        added = mix(0x2EA043, a)
        removed = mix(0xF85149, a)
        changed = mix(0xD29922, a)
        addedStrong = mix(0x2EA043, a * 2.2)
        removedStrong = mix(0xF85149, a * 2.2)
    }
}

final class DiffHeader: NSView {
    init(left: String, right: String, palette: EditorPalette) {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 24))
        clipsToBounds = true
        wantsLayer = true
        layer?.backgroundColor = NSColor(hex: palette.statusBar).cgColor
        let l = NSTextField(labelWithString: left), r = NSTextField(labelWithString: right)
        for f in [l, r] {
            f.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
            f.textColor = NSColor(hex: palette.foreground)
            f.lineBreakMode = .byTruncatingMiddle
            f.translatesAutoresizingMaskIntoConstraints = false
            addSubview(f)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            l.trailingAnchor.constraint(lessThanOrEqualTo: centerXAnchor, constant: -10),
            r.leadingAnchor.constraint(equalTo: centerXAnchor, constant: 10),
            r.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            l.centerYAnchor.constraint(equalTo: centerYAnchor), r.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Draws only the rows in view, so big files cost nothing up front.
final class DiffView: NSView {
    let left: [String], right: [String]
    let rows: [LineDiff.Row]
    let colors: DiffColors
    let font = Settings.shared.font
    let lineHeight: CGFloat
    let numberWidth: CGFloat

    init(left: [String], right: [String], rows: [LineDiff.Row], palette: EditorPalette) {
        self.left = left
        self.right = right
        self.rows = rows
        colors = DiffColors(palette)
        lineHeight = ceil(font.ascender - font.descender + font.leading) + 3
        let digits = String(max(left.count, right.count, 1)).count
        numberWidth = CGFloat(max(3, digits)) * ("0" as NSString).size(withAttributes: [.font: font]).width + 16
        super.init(frame: .zero)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    var contentHeight: CGFloat { CGFloat(rows.count) * lineHeight + 8 }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(width: newSize.width, height: max(contentHeight, superview?.bounds.height ?? 0)))
    }

    func jumpToDifference(forward: Bool) {
        let top = Int(visibleRect.minY / lineHeight)
        let idx: Int?
        if forward {
            // The start of the next block of differences below the top row.
            idx = rows.indices.first { $0 > top && rows[$0].kind != .same && rows[$0 - 1].kind == .same }
        } else {
            idx = rows.indices.last { $0 < top && rows[$0].kind != .same && ($0 == 0 || rows[$0 - 1].kind == .same) }
        }
        guard let i = idx else { NSSound.beep(); return }
        scroll(NSPoint(x: 0, y: max(0, CGFloat(i) * lineHeight - 3 * lineHeight)))
    }

    override func draw(_ dirtyRect: NSRect) {
        colors.background.setFill()
        // Since macOS 14 views don't clip to their bounds and dirtyRect
        // can be the whole window: fill only our own part.
        dirtyRect.intersection(bounds).fill()
        let half = floor(bounds.width / 2)
        let first = max(0, Int(dirtyRect.minY / lineHeight))
        let last = min(rows.count - 1, Int(dirtyRect.maxY / lineHeight))
        guard first <= last else { return }
        let textAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.foreground]
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        let numAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors.number, .paragraphStyle: para]
        for i in first...last {
            let row = rows[i]
            let y = CGFloat(i) * lineHeight
            for side in 0..<2 {
                let x0 = side == 0 ? 0 : half
                let line = side == 0 ? row.left : row.right
                let cell = NSRect(x: x0, y: y, width: half, height: lineHeight)
                let fill: NSColor? = {
                    guard let _ = line else { return colors.filler }
                    switch row.kind {
                    case .same: return nil
                    case .changed: return colors.changed
                    case .removed: return colors.removed
                    case .added: return colors.added
                    }
                }()
                if let fill { fill.setFill(); cell.fill() }
                guard let n = line else { continue }
                let text = side == 0 ? left[n] : right[n]
                ("\(n + 1)" as NSString).draw(in: NSRect(x: x0, y: y + 1, width: numberWidth - 8, height: lineHeight), withAttributes: numAttrs)
                let textX = x0 + numberWidth
                let clip = NSRect(x: textX, y: y, width: half - numberWidth - 4, height: lineHeight)
                NSGraphicsContext.saveGraphicsState()
                clip.clip()
                let shown = text.replacingOccurrences(of: "\t", with: "    ")
                if row.kind == .changed, let l = row.left, let r = row.right {
                    // The part of a changed line that differs, stronger.
                    let other = (side == 0 ? right[r] : left[l]).replacingOccurrences(of: "\t", with: "    ")
                    let span = Self.differingSpan(shown, other)
                    if span.length > 0 {
                        let ns = shown as NSString
                        let x1 = textX + ns.substring(to: span.location).size(withAttributes: textAttrs).width
                        let w = ns.substring(with: span).size(withAttributes: textAttrs).width
                        (side == 0 ? colors.removedStrong : colors.addedStrong).setFill()
                        NSRect(x: x1, y: y, width: max(2, w), height: lineHeight).fill()
                    }
                }
                (shown as NSString).draw(at: NSPoint(x: textX, y: y + 1), withAttributes: textAttrs)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        // The divider between the two sides.
        colors.number.withAlphaComponent(0.4).setFill()
        NSRect(x: half - 0.5, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
    }

    /// `a` minus its common prefix and suffix with `b` (UTF-16 range in `a`).
    static func differingSpan(_ a: String, _ b: String) -> NSRange {
        let x = Array(a.utf16), y = Array(b.utf16)
        var p = 0
        while p < x.count, p < y.count, x[p] == y[p] { p += 1 }
        var s = 0
        while s < x.count - p, s < y.count - p, x[x.count - 1 - s] == y[y.count - 1 - s] { s += 1 }
        return NSRange(location: p, length: x.count - p - s)
    }
}
