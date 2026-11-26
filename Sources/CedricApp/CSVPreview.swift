import AppKit
import CedricCore

/// The preview for CSV and TSV: a read-only grid. The first record is the
/// header; row numbers stay at the left when scrolling sideways; columns
/// resize; clicking a header sorts the grid (never the text); clicking a
/// cell puts the editor's caret in that field. The "#" cell above the row
/// numbers puts the rows back in file order (lit while the grid is sorted).
///
/// The table is view-based and virtual (cells are made for the rows on
/// screen only). Parsing (CSV in CedricCore) and sorting run on a
/// background queue from a copy of the text taken on the main thread;
/// a newer render drops an older result. Parses and sorts are counted
/// apart: every sort sorts the newest parsed table (kept apart from the
/// one shown, which may still wait for a sort), and a sort picked while
/// a parse is under way is applied to that parse's table when it lands.
/// At most `maxRows` records are shown (with a note), and in large mode
/// only the first `largeMaxChars` characters are read.
@MainActor
final class CSVPreview: NSObject, PreviewRenderer, NSTableViewDataSource, NSTableViewDelegate {
    static let maxRows = 50_000
    static let maxChars = 16_000_000
    static let largeMaxChars = 2_000_000
    /// Serial: the checks hold it to keep a parse under way.
    static let queue = DispatchQueue(label: "cedric.csv-preview", qos: .userInitiated)

    let container = CSVContainer()
    let scroll = NSScrollView()
    let table = GridTableView()
    private(set) var ruler: RowNumberRuler!
    let note = NSTextField(labelWithString: "")
    /// What is shown: the parsed records and the data rows' order (indexes into `rows`).
    private(set) var data = CSV.Table()
    private(set) var order: [Int] = []
    /// The newest parse started (render) and the newest sort picked. A
    /// parse's result is applied only while it is the newest; a sort's
    /// only while its table is still the newest parse and no other sort
    /// was picked since.
    private(set) var parseRevision = 0
    private var sortRevision = 0
    /// The newest parse that finished and its table: what every sort
    /// sorts. It is ahead of `data` while its table waits for a sort.
    private var parsed = (revision: 0, table: CSV.Table())
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private var textColor = NSColor.textColor
    /// Set by the tab: large mode, the text now, and where a click goes.
    var isLarge: () -> Bool = { false }
    var currentText: () -> NSString = { "" }
    var onSelectField: ((Int) -> Void)?
    /// Renders applied (the checks wait for one).
    private(set) var renders = 0
    /// After each render or sort: the preview bar's row count and Unsort.
    var onApplied: (() -> Void)?
    /// The preview bar's zoom: the grid's font and row height.
    var zoom: Double = 1 {
        didSet {
            guard zoom != oldValue else { return }
            font = NSFont(name: font.fontName, size: 12 * zoom) ?? .monospacedSystemFont(ofSize: 12 * zoom, weight: .regular)
            table.rowHeight = (18 * zoom).rounded()
            for (i, c) in table.tableColumns.enumerated() { c.width = width(column: i, rows: data.rows) }
            table.reloadData()
        }
    }
    /// Sorted by a column header (not in file order).
    var isSorted: Bool { !table.sortDescriptors.isEmpty }
    /// The row count for the bar.
    var rowCountText: String {
        PreviewBarItem.rowCountText(rows: min(order.count, Self.maxRows), capped: data.truncated || order.count > Self.maxRows)
    }

    /// The preview bar's Unsort (and the "#" cell): back to file order.
    func resetSort() { table.sortDescriptors = [] }

    var view: NSView { container }

    override init() {
        super.init()
        table.dataSource = self
        table.delegate = self
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.allowsMultipleSelection = false
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        table.intercellSpacing = NSSize(width: 1, height: 1)
        table.style = .plain
        table.rowHeight = 18
        table.onClickCell = { [weak self] r, c in self?.selectField(row: r, column: c) }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        ruler = RowNumberRuler(scrollView: scroll, table: table)
        ruler.number = { [weak self] row in
            guard let self, row < self.order.count else { return nil }
            return self.order[row] // the record's index: its line in a file without quoted line breaks
        }
        ruler.header.onClick = { [weak self] in self?.resetSort() }
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.isHidden = true
        container.scroll = scroll
        container.note = note
        container.addSubview(scroll)
        container.addSubview(note)
    }

    func handles(_ language: Language) -> Bool { language == .csv }

    func render(text: String, language: Language, palette: EditorPalette, baseURL: URL?, fileName: String?) {
        applyPalette(palette)
        parseRevision += 1
        let gen = parseRevision, sortGen = sortRevision
        // An immutable copy (the storage keeps changing), cut at a line end.
        let ns = text as NSString
        let limit = isLarge() ? Self.largeMaxChars : Self.maxChars
        var end = ns.length
        if end > limit {
            let nl = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: limit))
            end = nl.location == NSNotFound ? limit : NSMaxRange(nl)
        }
        let snapshot = ns.substring(to: end) as NSString
        let cut = end < ns.length
        let sort = table.sortDescriptors.first
        let maxRows = Self.maxRows
        Self.queue.async {
            let dialect = CSV.dialect(for: snapshot, fileName: fileName)
            // An unclosed quote ends at its line in the grid (with a warning),
            // instead of swallowing every row after it.
            var t = CSV.parse(snapshot, dialect: dialect, maxRows: maxRows + 1, stopUnclosedQuoteAtLineEnd: true)
            if cut { t.truncated = true }
            let order = Self.order(t.rows, sort)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard gen == self.parseRevision else { return }
                    self.parsed = (gen, t)
                    // A sort picked while this parsed: sort this table by it.
                    if sortGen == self.sortRevision { self.apply(t, order: order, parse: gen) } else { self.sort(t, parse: gen) }
                }
            }
        }
    }

    /// Sorts `t` (the table of parse `parse`) by the current sort off the
    /// main thread, then shows it, unless a newer parse or sort came first.
    private func sort(_ t: CSV.Table, parse: Int) {
        let rows = t.rows, sort = table.sortDescriptors.first, sortGen = sortRevision
        Self.queue.async {
            let order = Self.order(rows, sort)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard parse == self.parseRevision, sortGen == self.sortRevision else { return }
                    self.apply(t, order: order, parse: parse)
                }
            }
        }
    }

    nonisolated private static func order(_ rows: [[String]], _ sort: NSSortDescriptor?) -> [Int] {
        guard let sort, let key = sort.key, let col = Int(key.dropFirst()) else { return Array(rows.indices.dropFirst()) }
        return CSV.sortedOrder(rows, column: col, ascending: sort.ascending)
    }

    private func apply(_ t: CSV.Table, order: [Int], parse: Int) {
        data = t
        self.order = order
        let header = t.rows.first ?? []
        // Columns: kept (and their widths) while the count is the same.
        if table.tableColumns.count != t.columnCount {
            for c in table.tableColumns { table.removeTableColumn(c) }
            for i in 0..<t.columnCount {
                let c = NSTableColumn(identifier: .init("c\(i)"))
                c.resizingMask = .userResizingMask
                c.minWidth = 30
                c.maxWidth = 2_000
                c.width = width(column: i, rows: t.rows)
                c.sortDescriptorPrototype = NSSortDescriptor(key: "c\(i)", ascending: true)
                table.addTableColumn(c)
            }
        }
        for (i, c) in table.tableColumns.enumerated() {
            c.title = i < header.count && !header[i].isEmpty ? header[i] : String(localized: "Column \(i + 1)")
            c.headerCell.font = .systemFont(ofSize: 11, weight: .semibold)
        }
        table.reloadData()
        ruler.ruleThickness = max(28, CGFloat(String(t.rows.count).count) * 7.5 + 12)
        ruler.needsDisplay = true
        ruler.needsLayout = true
        ruler.header.isActive = isSorted
        ruler.header.needsDisplay = true
        let shown = min(order.count, Self.maxRows)
        var notes: [String] = []
        if let line = t.unclosedQuoteLine {
            notes.append(String(localized: "Unclosed quote on line \(line + 1). The preview ends that field at the end of its line."))
        }
        if t.truncated || order.count > Self.maxRows {
            notes.append(String(localized: "Showing the first \(shown.formatted()) rows. The preview is read-only."))
        }
        note.stringValue = notes.joined(separator: " ")
        note.textColor = t.unclosedQuoteLine != nil ? .systemOrange : .secondaryLabelColor
        note.toolTip = t.unclosedQuoteLine != nil
            ? String(localized: "A field starts with a quote that never closes, so spreadsheet apps would read the rest of the file as one cell.") : nil
        note.isHidden = notes.isEmpty
        container.needsLayout = true
        renders += 1
        onApplied?()
    }

    /// From the widest of the first 200 cells, in characters.
    private func width(column i: Int, rows: [[String]]) -> CGFloat {
        let charW = ("0" as NSString).size(withAttributes: [.font: font]).width
        var longest = 4
        for r in rows.prefix(200) where i < r.count { longest = max(longest, min(r[i].count, 48)) }
        return min(360, max(48, CGFloat(longest) * charW + 14))
    }

    private func applyPalette(_ p: EditorPalette) {
        let editor = Settings.shared.font
        font = NSFont(name: editor.fontName, size: 12 * zoom) ?? .monospacedSystemFont(ofSize: 12 * zoom, weight: .regular)
        textColor = NSColor(hex: p.foreground)
        table.backgroundColor = NSColor(hex: p.background)
        table.gridColor = NSColor(hex: p.currentLine)
        scroll.backgroundColor = NSColor(hex: p.background)
        ruler.background = NSColor(hex: p.statusBar)
        ruler.textColor = NSColor(hex: p.color(for: .comment))
        container.appearance = NSAppearance(named: p.isDark ? .darkAqua : .aqua)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { min(order.count, Self.maxRows) }

    /// The text of a cell as shown (row in view order).
    func cell(row: Int, column: Int) -> String {
        guard row < order.count else { return "" }
        let r = data.rows[order[row]]
        return column < r.count ? r[column] : ""
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let col = tableColumn, let i = tableView.tableColumns.firstIndex(of: col) else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let f = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? {
            let f = GridCell(labelWithString: "")
            f.identifier = id
            f.lineBreakMode = .byTruncatingTail
            f.cell?.usesSingleLineMode = true
            return f
        }()
        // Line breaks inside a field show as ⏎ on one line.
        let s = cell(row: row, column: i)
        f.stringValue = s.contains(where: \.isNewline) ? s.replacingOccurrences(of: "\r\n", with: "⏎").replacingOccurrences(of: "\n", with: "⏎") : s
        f.font = font
        f.textColor = textColor
        f.toolTip = s.count > 40 ? s : nil
        return f
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        ruler.header.isActive = isSorted
        sortRevision += 1
        // The newest parsed table (not the one shown, which may still wait
        // for an older sort). If a newer parse is under way, this is
        // dropped and that parse sorts its own table when it lands.
        sort(parsed.table, parse: parsed.revision)
    }

    /// A click on a cell: the caret goes to that field in the text.
    func selectField(row: Int, column: Int) {
        guard row < order.count else { return }
        let start = data.rowStarts[order[row]]
        let text = currentText()
        onSelectField?(min(text.length, CSV.fieldOffset(in: text, rowStart: start, column: column, dialect: data.dialect)))
    }

    func sync(line: Int, fraction: Double, language: Language) {
        // Only in file order: a sorted grid stays where the user put it.
        guard table.sortDescriptors.isEmpty, !data.rowLines.isEmpty else { return }
        var lo = 1, hi = data.rowLines.count - 1, best = 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if data.rowLines[mid] <= line { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        let row = max(0, best - 1)
        guard row < table.numberOfRows else { return }
        let y = table.rect(ofRow: row).minY
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: max(0, y - (table.headerView?.frame.height ?? 0))))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// The grid's table: a click on a cell counts even when its window
/// wasn't in front (the detached preview), so it moves the caret at once.
final class GridTableView: NSTableView {
    /// A single click on a cell (row and column in view order).
    var onClickCell: ((Int, Int) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let r = row(at: p), c = column(at: p)
        super.mouseDown(with: event)
        if event.clickCount == 1, r >= 0, c >= 0 { onClickCell?(r, c) }
    }
}

/// A cell's label: clicks go to the table.
final class GridCell: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The grid and, under it, the note.
final class CSVContainer: NSView {
    weak var scroll: NSScrollView?
    weak var note: NSTextField?
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let noteH: CGFloat = (note?.isHidden ?? true) ? 0 : 22
        scroll?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - noteH))
        (scroll?.verticalRulerView as? RowNumberRuler)?.needsLayout = true
        note?.frame = NSRect(x: 8, y: bounds.height - noteH + 3, width: max(0, bounds.width - 16), height: 16)
    }
}

/// Row numbers at the left of the grid, fixed when it scrolls sideways.
final class RowNumberRuler: NSRulerView {
    weak var table: NSTableView?
    /// The number shown for a row (in view order), 1-based is added here.
    var number: ((Int) -> Int?)?
    var background = NSColor.windowBackgroundColor { didSet { header.background = background } }
    var textColor = NSColor.secondaryLabelColor
    /// The "#" cell at the top, beside the table's header row.
    let header = RowNumberHeader()

    init(scrollView: NSScrollView, table: NSTableView) {
        self.table = table
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = table
        ruleThickness = 36
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        header.table = table
        addSubview(header)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    override var requiredThickness: CGFloat { ruleThickness }

    override func layout() {
        super.layout()
        placeHeader()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    /// The "#" cell level with the table's header row: the header's own
    /// frame, seen from here (it doesn't scroll up and down).
    func placeHeader() {
        guard let hv = table?.headerView, hv.window != nil, hv.window === window else { header.isHidden = true; return }
        let r = convert(hv.bounds, from: hv)
        header.isHidden = r.height <= 0
        header.frame = NSRect(x: 0, y: r.minY, width: bounds.width, height: r.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        // macOS 14: dirtyRect can extend past the bounds. Never draw outside them.
        let r = dirtyRect.intersection(bounds)
        guard !r.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).setClip()
        background.setFill()
        r.fill()
        drawHashMarksAndLabels(in: r)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let table, let number else { return }
        let visible = table.visibleRect
        let rows = table.rows(in: visible)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                                                    .foregroundColor: textColor]
        guard rows.length > 0 else { return }
        for row in rows.location..<NSMaxRange(rows) {
            guard let n = number(row) else { continue }
            let rr = convert(table.rect(ofRow: row), from: table)
            guard rr.maxY >= rect.minY, rr.minY <= rect.maxY else { continue }
            let s = "\(n)" as NSString
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: bounds.width - size.width - 6, y: rr.minY + (rr.height - size.height) / 2), withAttributes: attrs)
        }
    }
}

/// The "#" cell above the row numbers: the table header's look (its own
/// header cell draws the "#"), lit in the accent colour while the grid is
/// sorted. A click, or VoiceOver's press, puts the rows back in file order.
final class RowNumberHeader: NSView {
    weak var table: NSTableView?
    /// The grid is sorted: the cell is lit.
    var isActive = false {
        didSet { if isActive != oldValue { needsDisplay = true } }
    }
    var onClick: (() -> Void)?
    var background = NSColor.windowBackgroundColor { didSet { needsDisplay = true } }
    private var pressed = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The cell that draws the "#": a copy of the first column's header
    /// cell (its font and colours, in this appearance).
    func titleCell() -> NSTableHeaderCell {
        let cell = (table?.tableColumns.first?.headerCell.copy() as? NSTableHeaderCell) ?? NSTableHeaderCell(textCell: "")
        let font = cell.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let color: NSColor = isActive ? .controlAccentColor : .headerTextColor
        let weight: NSFont = isActive ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
        cell.attributedStringValue = NSAttributedString(string: "#", attributes: [.font: weight, .foregroundColor: color, .paragraphStyle: para])
        return cell
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        bounds.fill()
        if isActive || pressed {
            NSColor.controlAccentColor.withAlphaComponent(pressed ? 0.28 : 0.16).setFill()
            bounds.fill()
        }
        // Centred on the header row's titles, right-aligned as the numbers below.
        let title = titleCell().attributedStringValue
        let size = title.size()
        title.draw(at: NSPoint(x: bounds.width - size.width - 6, y: ((bounds.height - 1 - size.height) / 2).rounded()))
        // The line under the header row, as the table draws it.
        (table?.gridColor ?? .separatorColor).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    /// Tracks the press as a button does: pressed while the mouse is
    /// over it, a click if it is let go there.
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        var inside = true
        pressed = true
        display()
        while let e = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(e.locationInWindow, from: nil))
            if pressed != inside {
                pressed = inside
                display()
            }
            if e.type == .leftMouseUp { break }
        }
        pressed = false
        needsDisplay = true
        if inside { onClick?() }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { String(localized: "Row number, click to restore file order") }
    override func accessibilityValue() -> Any? { isActive ? String(localized: "Sorted") : String(localized: "File order") }
    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}
