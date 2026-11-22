import UIKit
import CedricCore

@MainActor
final class CSVPreviewController: UIViewController, UITableViewDataSource {
    static let maxRows = 50_000
    static let maxChars = 16_000_000
    static let largeMaxChars = 2_000_000
    private static let queue = DispatchQueue(label: "owlink.csv-preview", qos: .userInitiated)
    private let horizontal = UIScrollView()
    let table = UITableView(frame: .zero, style: .plain)
    let note = UILabel()
    private(set) var data = CSV.Table()
    private(set) var order: [Int] = []
    private(set) var renders = 0
    private var revision = 0
    private var sourceGeneration = 0
    private var source = ""
    private var sortColumn: Int?
    private var ascending = true
    var onSelectField: ((Int, Int) -> Void)?
    private let rowWidth: CGFloat = 48
    private let columnWidth: CGFloat = 150
    private let rowHeight: CGFloat = 44

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        horizontal.alwaysBounceHorizontal = false
        view.addSubview(horizontal)
        horizontal.addSubview(table)
        table.dataSource = self
        table.rowHeight = rowHeight
        table.accessibilityIdentifier = "preview.csv.table"
        table.separatorStyle = .none
        note.font = .preferredFont(forTextStyle: .footnote)
        note.textColor = .secondaryLabel
        note.numberOfLines = 0
        note.accessibilityIdentifier = "preview.csv.note"
        view.addSubview(note)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let noteHeight: CGFloat = note.isHidden ? 0 : min(80, note.sizeThatFits(CGSize(width: view.bounds.width - 16, height: 80)).height + 8)
        horizontal.frame = CGRect(x: 0, y: 54, width: view.bounds.width, height: max(0, view.bounds.height - 54 - noteHeight))
        note.frame = CGRect(x: 8, y: view.bounds.height - noteHeight, width: max(0, view.bounds.width - 16), height: noteHeight)
        let width = max(horizontal.bounds.width, rowWidth + CGFloat(data.columnCount) * columnWidth)
        table.frame = CGRect(x: 0, y: 0, width: width, height: horizontal.bounds.height)
        horizontal.contentSize = CGSize(width: width, height: horizontal.bounds.height)
        if let header = table.tableHeaderView, header.frame.width != width {
            header.frame.size.width = width
            table.tableHeaderView = header
        }
    }

    func render(text: String, fileName: String, large: Bool, sourceGeneration: Int) {
        loadViewIfNeeded()
        revision += 1
        let current = revision
        table.isUserInteractionEnabled = false
        let ns = text as NSString
        let limit = large ? Self.largeMaxChars : Self.maxChars
        var end = ns.length
        if end > limit {
            let newline = ns.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: limit))
            end = newline.location == NSNotFound ? limit : NSMaxRange(newline)
        }
        let snapshot = ns.substring(to: end)
        let cut = end < ns.length
        let column = sortColumn
        let asc = ascending
        let maxRows = Self.maxRows
        Self.queue.async { [weak self] in
            let input = snapshot as NSString
            let dialect = CSV.dialect(for: input, fileName: fileName)
            var parsed = CSV.parse(input, dialect: dialect, maxRows: maxRows + 1, stopUnclosedQuoteAtLineEnd: true)
            if cut { parsed.truncated = true }
            let order = column.map { CSV.sortedOrder(parsed.rows, column: $0, ascending: asc) }
                ?? Array(parsed.rows.indices.dropFirst())
            let result = parsed
            DispatchQueue.main.async {
                guard let self, self.revision == current else { return }
                self.data = result
                self.order = order
                self.source = snapshot
                self.sourceGeneration = sourceGeneration
                self.apply()
            }
        }
    }

    func sort(column: Int) {
        guard column >= 0, column < data.columnCount else { return }
        ascending = sortColumn == column ? !ascending : true
        sortColumn = column
        revision += 1
        let current = revision
        let rows = data.rows
        let asc = ascending
        Self.queue.async { [weak self] in
            let result = CSV.sortedOrder(rows, column: column, ascending: asc)
            DispatchQueue.main.async {
                guard let self, self.revision == current else { return }
                self.order = result
                self.apply()
            }
        }
    }

    private func apply() {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: table.bounds.width, height: rowHeight))
        header.backgroundColor = .secondarySystemBackground
        let titles = data.rows.first ?? []
        for column in 0..<data.columnCount {
            let button = UIButton(type: .system)
            let title = column < titles.count && !titles[column].isEmpty ? titles[column] : String(localized: "Column \(column + 1)")
            button.setTitle(title + (sortColumn == column ? (ascending ? " ↑" : " ↓") : ""), for: .normal)
            button.accessibilityLabel = String(localized: "Sort by \(title)")
            button.accessibilityIdentifier = "preview.csv.header.\(column)"
            button.layer.borderWidth = 0.5
            button.layer.borderColor = UIColor.separator.cgColor
            button.frame = CGRect(x: rowWidth + CGFloat(column) * columnWidth, y: 0, width: columnWidth, height: rowHeight)
            button.addAction(UIAction { [weak self] _ in self?.sort(column: column) }, for: .primaryActionTriggered)
            header.addSubview(button)
        }
        table.tableHeaderView = header
        var messages: [String] = []
        if let line = data.unclosedQuoteLine {
            messages.append(String(localized: "Unclosed quote on line \(line + 1). The preview ends that field at the end of its line."))
        }
        if data.truncated || order.count > Self.maxRows {
            let shown = min(order.count, Self.maxRows)
            messages.append(String(localized: "Showing the first \(shown.formatted()) rows. The preview is read-only."))
        }
        note.text = messages.joined(separator: " ")
        note.isHidden = messages.isEmpty
        table.isUserInteractionEnabled = true
        table.reloadData()
        view.setNeedsLayout()
        renders += 1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        min(order.count, Self.maxRows)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row") ?? UITableViewCell(style: .default, reuseIdentifier: "row")
        for view in cell.contentView.subviews { view.removeFromSuperview() }
        cell.selectionStyle = .none
        let row = order[indexPath.row]
        let number = UILabel(frame: CGRect(x: 0, y: 0, width: rowWidth, height: rowHeight))
        number.text = "\(row)"
        number.textAlignment = .center
        number.textColor = .secondaryLabel
        number.layer.borderWidth = 0.5
        number.layer.borderColor = UIColor.separator.cgColor
        number.accessibilityLabel = String(localized: "Row \(row)")
        cell.contentView.addSubview(number)
        for column in 0..<data.columnCount {
            let button = UIButton(type: .system)
            let value = column < data.rows[row].count ? data.rows[row][column] : ""
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            var configuration = UIButton.Configuration.plain()
            configuration.title = value
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8)
            button.configuration = configuration
            button.layer.borderWidth = 0.5
            button.layer.borderColor = UIColor.separator.cgColor
            button.frame = CGRect(x: rowWidth + CGFloat(column) * columnWidth, y: 0, width: columnWidth, height: rowHeight)
            button.accessibilityLabel = String(localized: "Row \(row), column \(column + 1): \(value)")
            button.accessibilityIdentifier = "preview.csv.cell.\(row).\(column)"
            button.addAction(UIAction { [weak self] _ in self?.selectField(row: row, column: column) }, for: .primaryActionTriggered)
            cell.contentView.addSubview(button)
        }
        return cell
    }

    func selectField(row: Int, column: Int) {
        guard row > 0, row < data.rowStarts.count, column >= 0, column < data.columnCount else { return }
        let offset = CSV.fieldOffset(in: source as NSString, rowStart: data.rowStarts[row], column: column, dialect: data.dialect)
        onSelectField?(offset, sourceGeneration)
    }
}
