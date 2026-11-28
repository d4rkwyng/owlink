import UIKit
import CedricCore

@MainActor
final class CSVPreviewController: UIViewController, UITableViewDataSource {
    static let maxRows = 50_000
    static let maxColumns = 128
    static let maxChars = 16_000_000
    static let largeMaxChars = 2_000_000
    private static let queue = DispatchQueue(label: "owlink.csv-preview", qos: .userInitiated)

    private let horizontal = UIScrollView()
    private let content = UIView()
    let table = UITableView(frame: .zero, style: .plain)
    private let header = UIView()
    /// The "#" cell above the row numbers: a tap restores file order, as
    /// the Mac's "#" header cell does (a third tap on a sorted column too).
    private let fileOrderButton = UIButton(type: .system)
    private var columnButtons: [UIButton] = []
    let note = UILabel()
    private(set) var data = CSV.Table()
    private(set) var order: [Int] = []
    private(set) var renders = 0
    private var renderRevision = 0
    private var sortRevision = 0
    private var sourceGeneration = 0
    private var source: NSString = ""
    private var pending: (table: CSV.Table, source: NSString, sourceGeneration: Int, revision: Int)?
    private var sortColumn: Int?
    private var ascending = true
    var sortColumnForTesting: Int? { sortColumn }
    var sourceForTesting: NSString { source }
    var headerForTesting: UIView { header }
    private var pendingFraction = 0.0
    private var announceSort = false
    private var rowWidth: CGFloat = 48
    private var columnWidth: CGFloat = 150
    private var columnWidths: [CGFloat] = []
    private var columnStarts: [CGFloat] = []
    private var rowHeight: CGFloat = 40
    private var headerHeight: CGFloat = 40
    private var scaledFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var palette = EditorPalettes.light
    var onSelectField: ((Int, Int) -> Void)?
    var isSourceCurrent: (() -> Bool)?
    var scrollFraction: Double {
        get { Self.finiteFraction(ScrollSync.fraction(offset: table.contentOffset.y,
                                                      contentHeight: table.contentSize.height,
                                                      visibleHeight: table.bounds.height,
                                                      insetTop: table.adjustedContentInset.top,
                                                      insetBottom: table.adjustedContentInset.bottom)) }
        set {
            pendingFraction = Self.finiteFraction(newValue)
            applyPendingFractionIfReady()
        }
    }

    private static func finiteFraction(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(hex: palette.background)
        horizontal.showsVerticalScrollIndicator = false
        horizontal.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(horizontal)
        horizontal.addSubview(content)
        header.backgroundColor = UIColor(hex: palette.gutterBackground)
        header.accessibilityIdentifier = "preview.csv.header"
        content.addSubview(header)
        fileOrderButton.accessibilityIdentifier = "preview.csv.header.fileOrder"
        fileOrderButton.accessibilityLabel = String(localized: "Row number")
        fileOrderButton.accessibilityHint = String(localized: "Restores file order")
        fileOrderButton.addAction(UIAction { [weak self] _ in self?.restoreFileOrder() }, for: .primaryActionTriggered)
        header.addSubview(fileOrderButton)
        table.dataSource = self
        table.rowHeight = rowHeight
        table.separatorStyle = .none
        table.showsHorizontalScrollIndicator = false
        table.accessibilityIdentifier = "preview.csv.table"
        content.addSubview(table)
        note.font = .preferredFont(forTextStyle: .footnote)
        note.adjustsFontForContentSizeCategory = true
        note.textColor = UIColor(hex: palette.gutterForeground)
        note.numberOfLines = 0
        note.accessibilityIdentifier = "preview.csv.note"
        view.addSubview(note)
        NSLayoutConstraint.activate([
            horizontal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            horizontal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            horizontal.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            horizontal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            note.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            note.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (self: Self, _: UITraitCollection) in
            self.applyTypography()
        }
        applyTypography()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let visibleWidth = max(0, horizontal.bounds.width)
        let visibleHeight = max(0, horizontal.bounds.height - (note.isHidden ? 0 : note.bounds.height))
        let width = max(visibleWidth, rowWidth + CGFloat(min(data.columnCount, Self.maxColumns)) * columnWidth)
        content.frame = CGRect(x: 0, y: 0, width: width, height: horizontal.bounds.height)
        header.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
        table.frame = CGRect(x: 0, y: headerHeight, width: width, height: max(0, visibleHeight - headerHeight))
        horizontal.contentSize = CGSize(width: width, height: horizontal.bounds.height)
        applyPendingFractionIfReady()
    }

    func applyTheme(_ palette: EditorPalette, zoom: Double) {
        self.palette = palette
        viewIfLoaded?.backgroundColor = UIColor(hex: palette.background)
        header.backgroundColor = UIColor(hex: palette.gutterBackground)
        note.textColor = UIColor(hex: palette.gutterForeground)
        table.backgroundColor = UIColor(hex: palette.background)
        applyTypography(zoom: zoom)
        if isViewLoaded, !data.rows.isEmpty { apply() }
        table.reloadData()
    }

    private func applyTypography(zoom: Double = 1) {
        let base = UIFont.monospacedSystemFont(ofSize: CGFloat(AppSettings.fontSize * zoom), weight: .regular)
        scaledFont = UIFontMetrics(forTextStyle: .body).scaledFont(for: base, compatibleWith: traitCollection)
        rowHeight = UIFontMetrics(forTextStyle: .body).scaledValue(for: 40 * zoom, compatibleWith: traitCollection)
        headerHeight = UIFontMetrics(forTextStyle: .body).scaledValue(for: 40 * zoom, compatibleWith: traitCollection)
        table.rowHeight = rowHeight
        note.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .preferredFont(forTextStyle: .footnote),
                                                                      compatibleWith: traitCollection)
        view.setNeedsLayout()
    }

    func render(text: NSString, fileName: String, large: Bool, sourceGeneration: Int, scrollFraction: Double) {
        loadViewIfNeeded()
        renderRevision += 1
        let revision = renderRevision
        pendingFraction = Self.finiteFraction(scrollFraction)
        let limit = large ? Self.largeMaxChars : Self.maxChars
        var end = text.length
        if end > limit {
            let newline = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: limit))
            end = newline.location == NSNotFound ? limit : NSMaxRange(newline)
        }
        let snapshot = text.substring(to: end) as NSString
        let cut = end < text.length
        Self.queue.async { [weak self] in
            let dialect = CSV.dialect(for: snapshot, fileName: fileName)
            var parsed = CSV.parse(snapshot, dialect: dialect, maxRows: Self.maxRows + 1,
                                   stopUnclosedQuoteAtLineEnd: true,
                                   maxColumns: Self.maxColumns + (dialect.edgeDelimiters ? 2 : 0))
            if cut { parsed.truncated = true }
            DispatchQueue.main.async {
                guard let self, self.renderRevision == revision else { return }
                self.pending = (parsed, snapshot, sourceGeneration, revision)
                self.sortPending()
            }
        }
    }

    func sort(column: Int) {
        let columnCount = pending?.table.columnCount ?? data.columnCount
        guard column >= 0, column < min(columnCount, Self.maxColumns) else { return }
        if sortColumn != column {
            sortColumn = column
            ascending = true
        } else if ascending {
            ascending = false
        } else {
            sortColumn = nil
            ascending = true
        }
        sortRevision += 1
        announceSort = true
        if pending != nil { sortPending() } else { sortDisplayedData() }
    }

    /// Back to file order (the "#" cell). Nothing to do when not sorted.
    func restoreFileOrder() {
        guard sortColumn != nil else { return }
        sortColumn = nil
        ascending = true
        sortRevision += 1
        announceSort = true
        if pending != nil { sortPending() } else { sortDisplayedData() }
    }

    private func sortPending() {
        guard let pending else { return }
        let table = pending.table
        let source = pending.source
        let sourceGeneration = pending.sourceGeneration
        let render = pending.revision
        let sorting = sortRevision
        let column = sortColumn
        let ascending = ascending
        Self.queue.async { [weak self] in
            let order = Self.order(table.rows, column: column, ascending: ascending)
            DispatchQueue.main.async {
                guard let self, self.renderRevision == render, self.sortRevision == sorting,
                      self.pending?.revision == render else { return }
                self.data = table
                self.source = source
                self.sourceGeneration = sourceGeneration
                self.order = order
                self.pending = nil
                self.apply()
            }
        }
    }

    private func sortDisplayedData() {
        let table = data
        let render = renderRevision
        let sorting = sortRevision
        let column = sortColumn
        let ascending = ascending
        Self.queue.async { [weak self] in
            let order = Self.order(table.rows, column: column, ascending: ascending)
            DispatchQueue.main.async {
                guard let self, self.renderRevision == render, self.sortRevision == sorting,
                      self.pending == nil else { return }
                self.order = order
                self.apply()
            }
        }
    }

    nonisolated private static func order(_ rows: [[String]], column: Int?, ascending: Bool) -> [Int] {
        guard let column else { return Array(rows.indices.dropFirst()) }
        return CSV.sortedOrder(rows, column: column, ascending: ascending)
    }

    private func apply() {
        let headerCells = data.rows.first ?? []
        let visibleColumns = min(data.columnCount, Self.maxColumns)
        if columnButtons.count != visibleColumns {
            columnButtons.forEach { $0.removeFromSuperview() }
            columnButtons = (0..<visibleColumns).map { column in
                let button = UIButton(type: .system)
                button.tag = column
                button.accessibilityIdentifier = "preview.csv.header.\(column)"
                button.addAction(UIAction { [weak self] _ in self?.sort(column: column) }, for: .primaryActionTriggered)
                header.addSubview(button)
                return button
            }
        }
        let fontWidth = max(6, scaledFont.pointSize * 0.62)
        rowWidth = max(48, UIFontMetrics(forTextStyle: .footnote).scaledValue(for: 10 * CGFloat(String(max(1, order.max() ?? 1)).count) + 12,
                                                                              compatibleWith: traitCollection))
        columnWidths = (0..<visibleColumns).map { column in
            let longest = data.rows.prefix(200).reduce(4) { current, row in
                max(current, column < row.count ? min(row[column].count, 48) : 0)
            }
            return min(360, max(64, CGFloat(longest) * fontWidth + 18))
        }
        columnWidth = columnWidths.max() ?? 150
        let starts = columnWidths.reduce(into: [rowWidth]) { $0.append($0.last! + $1) }
        columnStarts = starts
        var hash = UIButton.Configuration.plain()
        hash.title = "#"
        hash.contentInsets = .zero
        fileOrderButton.configuration = hash
        fileOrderButton.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: scaledFont.pointSize, weight: .semibold)
        // Lit while sorted, as the Mac's "#" cell is: a tap does something.
        fileOrderButton.tintColor = sortColumn == nil ? UIColor(hex: palette.gutterForeground) : .tintColor
        fileOrderButton.backgroundColor = UIColor(hex: palette.gutterBackground)
        fileOrderButton.layer.borderWidth = 0.5
        fileOrderButton.layer.borderColor = UIColor(hex: palette.currentLine).cgColor
        fileOrderButton.frame = CGRect(x: 0, y: 0, width: rowWidth, height: headerHeight)
        fileOrderButton.accessibilityTraits = sortColumn == nil ? [.button, .notEnabled] : .button
        for (column, button) in columnButtons.enumerated() {
            let title = column < headerCells.count && !headerCells[column].isEmpty
                ? headerCells[column] : String(localized: "Column \(column + 1)")
            var config = UIButton.Configuration.plain()
            config.title = title + (sortColumn == column ? (ascending ? " ↑" : " ↓") : "")
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
            button.configuration = config
            button.titleLabel?.font = UIFont.monospacedSystemFont(ofSize: scaledFont.pointSize, weight: .semibold)
            button.tintColor = UIColor(hex: palette.foreground)
            button.backgroundColor = UIColor(hex: palette.gutterBackground)
            button.layer.borderWidth = 0.5
            button.layer.borderColor = UIColor(hex: palette.currentLine).cgColor
            button.frame = CGRect(x: starts[column], y: 0, width: columnWidths[column], height: headerHeight)
            button.accessibilityLabel = String(localized: "Sort by \(title)")
            button.accessibilityValue = sortColumn == column
                ? String(localized: ascending ? "Ascending" : "Descending") : nil
            button.accessibilityTraits = sortColumn == column ? [.button, .selected] : .button
        }
        let messages: [String] = [
            data.unclosedQuoteLine.map { String(localized: "Unclosed quote on line \($0 + 1). The preview ends that field at the end of its line.") },
            data.truncated || order.count > Self.maxRows
                ? String(localized: "Showing the first \(min(order.count, Self.maxRows).formatted()) rows. The preview is read-only.") : nil,
            data.columnCount > Self.maxColumns || data.truncatedColumns
                ? String(localized: "Showing the first \(Self.maxColumns) columns.") : nil,
        ].compactMap { $0 }
        note.text = messages.joined(separator: " ")
        note.isHidden = messages.isEmpty
        view.setNeedsLayout()
        table.reloadData()
        renders += 1
        if announceSort {
            announceSort = false
            UIAccessibility.post(notification: .layoutChanged, argument: header)
        }
        applyPendingFractionIfReady()
    }

    func numberOfSections(in tableView: UITableView) -> Int { 1 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        min(order.count, Self.maxRows)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = (tableView.dequeueReusableCell(withIdentifier: CSVGridCell.identifier) as? CSVGridCell)
            ?? CSVGridCell(style: .default, reuseIdentifier: CSVGridCell.identifier)
        let sourceRow = order[indexPath.row]
        cell.configure(row: sourceRow, values: data.rows[sourceRow], columns: min(data.columnCount, Self.maxColumns),
                       rowWidth: rowWidth, columnWidths: columnWidths, columnStarts: columnStarts, rowHeight: rowHeight,
                       font: scaledFont, palette: palette)
        cell.onSelectField = { [weak self] row, column in self?.selectField(row: row, column: column) }
        return cell
    }

    func selectField(row: Int, column: Int) {
        guard isSourceCurrent?() != false, row > 0, row < data.rowStarts.count,
              column >= 0, column < min(data.columnCount, Self.maxColumns) else { return }
        let offset = CSV.fieldOffset(in: source, rowStart: data.rowStarts[row], column: column, dialect: data.dialect)
        onSelectField?(min(source.length, offset), sourceGeneration)
    }

    private func applyPendingFractionIfReady() {
        guard isViewLoaded, table.bounds.height > 0 else { return }
        if table.contentSize.height <= table.bounds.height {
            pendingFraction = 0
            return
        }
        let fraction = Self.finiteFraction(pendingFraction)
        let y = ScrollSync.offset(fraction: fraction, contentHeight: table.contentSize.height,
                                  visibleHeight: table.bounds.height, insetTop: table.adjustedContentInset.top,
                                  insetBottom: table.adjustedContentInset.bottom)
        guard y.isFinite else { return }
        table.setContentOffset(CGPoint(x: table.contentOffset.x, y: y), animated: false)
        pendingFraction = 0
    }
}

@MainActor
private final class CSVGridCell: UITableViewCell {
    static let identifier = "preview.csv.row"
    private let rowNumber = UILabel()
    private var buttons: [UIButton] = []
    var onSelectField: ((Int, Int) -> Void)?
    private var sourceRow = 0

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        contentView.addSubview(rowNumber)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(row: Int, values: [String], columns: Int, rowWidth: CGFloat, columnWidths: [CGFloat], columnStarts: [CGFloat],
                  rowHeight: CGFloat, font: UIFont, palette: EditorPalette) {
        sourceRow = row
        while buttons.count < columns {
            let button = UIButton(type: .system)
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.tag = buttons.count
            let column = buttons.count
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.onSelectField?(self.sourceRow, column)
            }, for: .primaryActionTriggered)
            contentView.addSubview(button)
            buttons.append(button)
        }
        for index in buttons.indices {
            let button = buttons[index]
            button.isHidden = index >= columns
            guard index < columns else { continue }
            let value = index < values.count ? values[index] : ""
            var config = UIButton.Configuration.plain()
            config.title = value
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
            button.configuration = config
            button.tintColor = UIColor(hex: palette.foreground)
            button.backgroundColor = UIColor(hex: palette.background)
            button.titleLabel?.font = font
            button.layer.borderWidth = 0.5
            button.layer.borderColor = UIColor(hex: palette.currentLine).cgColor
            button.frame = CGRect(x: columnStarts[index], y: 0, width: columnWidths[index], height: rowHeight)
            button.accessibilityLabel = String(localized: "Row \(row), column \(index + 1)")
            button.accessibilityValue = value
            button.accessibilityIdentifier = "preview.csv.cell.\(row).\(index)"
        }
        rowNumber.frame = CGRect(x: 0, y: 0, width: rowWidth, height: rowHeight)
        rowNumber.text = "\(row)"
        rowNumber.textAlignment = .center
        rowNumber.font = UIFont.monospacedSystemFont(ofSize: max(9, font.pointSize * 0.85), weight: .regular)
        rowNumber.textColor = UIColor(hex: palette.gutterForeground)
        rowNumber.backgroundColor = UIColor(hex: palette.gutterBackground)
        rowNumber.layer.borderWidth = 0.5
        rowNumber.layer.borderColor = UIColor(hex: palette.currentLine).cgColor
        rowNumber.accessibilityLabel = String(localized: "Row \(row)")
        backgroundColor = UIColor(hex: palette.background)
        contentView.backgroundColor = UIColor(hex: palette.background)
    }
}
