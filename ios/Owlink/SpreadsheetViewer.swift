import UIKit
import CedricCore

// The read-only spreadsheet grid: an .xlsx / .xlsm workbook (every sheet,
// with tabs) or a CSV / TSV file, drawn natively rather than by Quick Look
// (which draws a sheet tiny in the top-left corner). Nothing here writes
// to, moves or deletes the file; Share hands the file's URL to the system
// share sheet, and Edit as Text (CSV / TSV only) opens it in the editor.

/// The grid's geometry: a frozen header row of column letters and a frozen
/// column of row numbers, column widths from the content, one row height,
/// all times `scale` (pinch zoom; fitted to the width on open).
final class SpreadsheetGridLayout: UICollectionViewLayout {
    var table: SpreadsheetTable?
    /// Column widths at scale 1.
    private(set) var widths: [CGFloat] = []
    private var starts: [CGFloat] = [0]
    var scale: CGFloat = 1
    static let baseRowHeight: CGFloat = 30
    static let baseHeaderHeight: CGFloat = 26
    private(set) var baseRowHeaderWidth: CGFloat = 44

    var rowHeight: CGFloat { Self.baseRowHeight * scale }
    var headerHeight: CGFloat { Self.baseHeaderHeight * scale }
    var rowHeaderWidth: CGFloat { baseRowHeaderWidth * scale }

    /// The sheet's width and height at scale 1.
    var baseWidth: CGFloat { baseRowHeaderWidth + (starts.last ?? 0) }
    var baseHeight: CGFloat { Self.baseHeaderHeight + CGFloat(table?.rowCount ?? 0) * Self.baseRowHeight }

    static let minColumnWidth: CGFloat = 56
    static let maxColumnWidth: CGFloat = 280
    /// Room around a cell's text: SpreadsheetGridCell.inset on each side, and some.
    static let padding: CGFloat = 2 * SpreadsheetGridCell.inset + 4

    /// Measures the columns: the widest of the first rows' text (at the
    /// grid's base fonts: numbers and dates in the digit font they show
    /// in), plus the cell's padding, between 56 and 280 pt.
    func measure(font: UIFont, numberFont: UIFont, headerFont: UIFont) {
        guard let t = table else { widths = []; starts = [0]; return }
        var w = (0..<t.columnCount).map { c in
            ceil((SpreadsheetTable.columnName(c) as NSString).size(withAttributes: [.font: headerFont]).width) + Self.padding
        }
        let sample = min(t.rowCount, 500)
        for r in 0..<sample {
            for (c, cell) in t.row(r) where c < w.count {
                // A multi-line cell is as wide as its longest line.
                let line = cell.text.split(whereSeparator: \.isNewline).map(String.init).max { $0.count < $1.count } ?? cell.text
                let width = ceil((line as NSString).size(withAttributes: [.font: cell.alignsRight ? numberFont : font]).width) + Self.padding
                if width > w[c] { w[c] = min(width, Self.maxColumnWidth) }
            }
        }
        widths = w.map { max(Self.minColumnWidth, min(Self.maxColumnWidth, $0)) }
        starts = [0]
        for x in widths { starts.append(starts.last! + x) }
        let digits = String(max(t.rowCount, 1))
        baseRowHeaderWidth = max(40, ceil((digits as NSString).size(withAttributes: [.font: headerFont]).width) + Self.padding)
    }

    /// Widens every column by the same factor so the sheet fills `width`
    /// (a narrow sheet on a wide screen), at scale 1.
    func stretch(toFill width: CGFloat) {
        let columns = starts.last ?? 0
        guard columns > 0, baseWidth < width else { return }
        let f = (width - baseRowHeaderWidth) / columns
        widths = widths.map { $0 * f }
        starts = [0]
        for x in widths { starts.append(starts.last! + x) }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: baseWidth * scale, height: baseHeight * scale)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { true }

    private func columnRange(_ minX: CGFloat, _ maxX: CGFloat) -> Range<Int> {
        guard !widths.isEmpty else { return 0..<0 }
        func index(_ x: CGFloat) -> Int {
            // The column at x (scale 1, x from the first data column).
            var lo = 0, hi = widths.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if starts[mid] <= x { lo = mid } else { hi = mid - 1 }
            }
            return lo
        }
        let a = index(max(0, minX / scale - baseRowHeaderWidth))
        let b = index(max(0, maxX / scale - baseRowHeaderWidth))
        return a..<(b + 1)
    }

    private func rowRange(_ minY: CGFloat, _ maxY: CGFloat) -> Range<Int> {
        let n = table?.rowCount ?? 0
        guard n > 0 else { return 0..<0 }
        let a = max(0, Int(floor((minY - headerHeight) / rowHeight)))
        let b = min(n - 1, Int(floor((maxY - headerHeight) / rowHeight)))
        return a > b ? 0..<0 : a..<(b + 1)
    }

    /// Item 0 of each section is the row number; section 0 the header row.
    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let row = indexPath.section - 1, col = indexPath.item - 1
        guard col < widths.count, row < (table?.rowCount ?? 0) else { return nil }
        let a = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        let offset = collectionView.map { $0.contentOffset } ?? .zero
        let inset = collectionView?.adjustedContentInset ?? .zero
        var x = col < 0 ? 0 : rowHeaderWidth + starts[col] * scale
        var y = row < 0 ? 0 : headerHeight + CGFloat(row) * rowHeight
        let w = col < 0 ? rowHeaderWidth : widths[col] * scale
        let h = row < 0 ? headerHeight : rowHeight
        // Frozen: the header row stays at the top, the numbers at the left.
        if row < 0 { y = max(0, offset.y + inset.top) }
        if col < 0 { x = max(0, offset.x + inset.left) }
        a.frame = CGRect(x: x, y: y, width: w, height: h)
        a.zIndex = row < 0 && col < 0 ? 3 : (row < 0 || col < 0 ? 2 : 0)
        return a
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let t = table, t.rowCount > 0 || !widths.isEmpty else { return [] }
        let cols = columnRange(rect.minX, rect.maxX)
        let rows = rowRange(rect.minY, rect.maxY)
        var out: [UICollectionViewLayoutAttributes] = []
        out.reserveCapacity((rows.count + 1) * (cols.count + 1))
        for r in rows {
            for c in cols { if let a = layoutAttributesForItem(at: IndexPath(item: c + 1, section: r + 1)) { out.append(a) } }
            if let a = layoutAttributesForItem(at: IndexPath(item: 0, section: r + 1)) { out.append(a) }
        }
        for c in cols { if let a = layoutAttributesForItem(at: IndexPath(item: c + 1, section: 0)) { out.append(a) } }
        if let a = layoutAttributesForItem(at: IndexPath(item: 0, section: 0)) { out.append(a) }
        return out
    }
}

/// One cell: a value, a column letter, or a row number.
final class SpreadsheetGridCell: UICollectionViewCell {
    let label = UILabel()
    private let line = CALayer()
    var isHeader = false
    /// The text's inset from each side at scale 1.
    static let inset: CGFloat = 8
    /// The grid's zoom: the inset scales with the text.
    var scale: CGFloat = 1 { didSet { if scale != oldValue { setNeedsLayout() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.lineBreakMode = .byTruncatingTail
        label.numberOfLines = 1
        contentView.addSubview(label)
        layer.addSublayer(line)
        isAccessibilityElement = true
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitDisplayScale.self]) { (self: Self, _) in
            self.updateLines()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: min(Self.inset * scale, bounds.width / 8), dy: 0)
        updateLines()
    }

    /// Hairline grid lines on the right and bottom edges.
    private func updateLines() {
        let px = 1 / max(1, traitCollection.displayScale)
        line.frame = bounds
        line.borderWidth = 0
        line.sublayers?.forEach { $0.removeFromSuperlayer() }
        let color = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        for r in [CGRect(x: bounds.width - px, y: 0, width: px, height: bounds.height),
                  CGRect(x: 0, y: bounds.height - px, width: bounds.width, height: px)] {
            let l = CALayer()
            l.frame = r
            l.backgroundColor = color
            line.addSublayer(l)
        }
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    func updateSelection() {
        guard !isHeader else { return }
        contentView.layer.borderWidth = isSelected ? 2 : 0
        contentView.layer.borderColor = tintColor.cgColor
        backgroundColor = isSelected ? tintColor.withAlphaComponent(0.12) : .systemBackground
        if isSelected { accessibilityTraits.insert(.selected) } else { accessibilityTraits.remove(.selected) }
    }
}

/// The grid: a UICollectionView (lazy, reused cells) with the frozen
/// headers, pinch zoom, a tap to select a cell, and Copy from its menu.
final class SpreadsheetGridView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    let layout = SpreadsheetGridLayout()
    let collectionView: UICollectionView
    private(set) var table: SpreadsheetTable?
    var pasteboard = UIPasteboard.general
    /// Fitted to the width since the table was shown (until a pinch).
    private var fitted = false
    private var fittedWidth: CGFloat = 0
    static let minScale: CGFloat = 0.4, maxScale: CGFloat = 3
    /// The smallest scale fitting to the width goes to: smaller than this
    /// is unreadable, so a wide sheet scrolls sideways instead.
    static let minFitScale: CGFloat = 0.7
    private var pinchStart: CGFloat = 1
    private let font = UIFont.systemFont(ofSize: 15)
    private lazy var numberFont = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular)
    private let headerFont = UIFont.systemFont(ofSize: 13, weight: .semibold)

    static func indexPath(row: Int, column: Int) -> IndexPath { IndexPath(item: column + 1, section: row + 1) }

    override init(frame: CGRect) {
        collectionView = UICollectionView(frame: frame, collectionViewLayout: layout)
        super.init(frame: frame)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .systemBackground
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(SpreadsheetGridCell.self, forCellWithReuseIdentifier: "cell")
        collectionView.allowsSelection = true
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.accessibilityIdentifier = "viewer.grid"
        collectionView.accessibilityLabel = String(localized: "Spreadsheet")
        collectionView.showsHorizontalScrollIndicator = true
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        collectionView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ table: SpreadsheetTable) {
        self.table = table
        layout.table = table
        layout.scale = 1
        layout.measure(font: font, numberFont: numberFont, headerFont: headerFont)
        fitted = false
        collectionView.reloadData()
        collectionView.contentOffset = CGPoint(x: -collectionView.adjustedContentInset.left, y: -collectionView.adjustedContentInset.top)
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = availableWidth
        guard table != nil, width > 0, !fitted || fittedWidth != width else { return }
        fit()
    }

    private var availableWidth: CGFloat {
        let inset = collectionView.adjustedContentInset
        return collectionView.bounds.width - inset.left - inset.right
    }

    /// Fit to the width: a narrow sheet's columns widen to fill it; a wide
    /// one is scaled down to fit, but no smaller than `minFitScale`.
    func fit() {
        let width = availableWidth
        guard width > 0 else { return }
        layout.measure(font: font, numberFont: numberFont, headerFont: headerFont)
        if layout.baseWidth <= width {
            layout.stretch(toFill: width)
            layout.scale = 1
        } else {
            layout.scale = max(Self.minFitScale, width / layout.baseWidth)
        }
        fitted = true
        fittedWidth = width
        layout.invalidateLayout()
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
    }

    /// Zooms to `scale`, keeping the sheet point under `anchor` (in the
    /// collection view's bounds) where it is.
    func setScale(_ scale: CGFloat, anchor: CGPoint) {
        let s = min(Self.maxScale, max(Self.minScale, scale))
        let old = layout.scale
        guard s != old else { return }
        let off = collectionView.contentOffset
        let content = CGPoint(x: (off.x + anchor.x) / old, y: (off.y + anchor.y) / old)
        layout.scale = s
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        let inset = collectionView.adjustedContentInset
        let size = layout.collectionViewContentSize
        let maxX = max(-inset.left, size.width - collectionView.bounds.width + inset.right)
        let maxY = max(-inset.top, size.height - collectionView.bounds.height + inset.bottom)
        collectionView.contentOffset = CGPoint(x: min(maxX, max(-inset.left, content.x * s - anchor.x)),
                                               y: min(maxY, max(-inset.top, content.y * s - anchor.y)))
        let visible = collectionView.indexPathsForVisibleItems
        if !visible.isEmpty { collectionView.reconfigureItems(at: visible) }
    }

    @objc private func pinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStart = layout.scale
        case .changed:
            let p = g.location(in: collectionView)
            setScale(pinchStart * g.scale, anchor: CGPoint(x: p.x - collectionView.contentOffset.x, y: p.y - collectionView.contentOffset.y))
        default: break
        }
    }

    // MARK: Data

    func numberOfSections(in collectionView: UICollectionView) -> Int { (table?.rowCount ?? 0) + 1 }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        (table?.columnCount ?? 0) + 1
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath) as! SpreadsheetGridCell
        let row = indexPath.section - 1, col = indexPath.item - 1
        let s = layout.scale
        cell.isHeader = row < 0 || col < 0
        cell.scale = s
        cell.contentView.layer.borderWidth = 0
        if cell.isHeader {
            cell.backgroundColor = .secondarySystemBackground
            cell.label.font = headerFont.withSize(headerFont.pointSize * s)
            cell.label.textColor = .secondaryLabel
            cell.label.textAlignment = .center
            cell.accessibilityTraits = .header
            cell.accessibilityValue = nil
            if row < 0, col < 0 {
                cell.label.text = nil
                cell.accessibilityLabel = nil
                cell.isAccessibilityElement = false
            } else if row < 0 {
                let name = SpreadsheetTable.columnName(col)
                cell.label.text = name
                cell.accessibilityLabel = String(localized: "Column \(name)")
                cell.isAccessibilityElement = true
            } else {
                cell.label.text = String(row + 1)
                cell.accessibilityLabel = String(localized: "Row \(row + 1)")
                cell.isAccessibilityElement = true
            }
        } else {
            let value = table?[row, col]
            cell.backgroundColor = .systemBackground
            let base = value?.alignsRight == true ? numberFont : font
            cell.label.font = base.withSize(base.pointSize * s)
            cell.label.text = value.map { $0.text.replacingOccurrences(of: "\n", with: " ") }
            switch value?.kind {
            case .error?: cell.label.textColor = .systemRed
            case .boolean?: cell.label.textColor = .label
            default: cell.label.textColor = .label
            }
            cell.label.textAlignment = value?.alignsRight == true ? .right : (value?.kind == .boolean || value?.kind == .error ? .center : .natural)
            let name = SpreadsheetTable.cellName(row: row, column: col)
            cell.accessibilityLabel = value.map { "\(name), \($0.text)" } ?? String(localized: "\(name), empty")
            cell.accessibilityTraits = .staticText
            cell.isAccessibilityElement = true
            cell.accessibilityCustomActions = value == nil ? nil : [UIAccessibilityCustomAction(name: String(localized: "Copy")) { [weak self] _ in
                self?.copyCell(row: row, column: col)
                return true
            }]
            cell.updateSelection()
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        indexPath.section > 0 && indexPath.item > 0
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        becomeFirstResponder()
    }

    /// Long press: Copy the cell's text.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let ip = indexPaths.first, ip.section > 0, ip.item > 0 else { return nil }
        let row = ip.section - 1, col = ip.item - 1
        guard table?[row, col] != nil else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                self?.copyCell(row: row, column: col)
            }])
        }
    }

    func copyCell(row: Int, column: Int) {
        guard let text = table?[row, column]?.text else { return }
        pasteboard.string = text
    }

    // ⌘C copies the selected cell (a hardware keyboard).
    override var canBecomeFirstResponder: Bool { true }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(copy(_:)) { return collectionView.indexPathsForSelectedItems?.isEmpty == false }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) {
        guard let ip = collectionView.indexPathsForSelectedItems?.first else { return }
        copyCell(row: ip.section - 1, column: ip.item - 1)
    }
}

/// The viewer screen: the bar (file name, "Excel spreadsheet · 12 KB",
/// Done, Share, and Edit as Text for CSV / TSV), sheet tabs for a
/// workbook with several sheets, a notice when rows were left out, and the
/// grid, or a message (empty, damaged, password-protected).
final class SpreadsheetViewerController: UIViewController, DocumentViewer {
    enum State: Equatable {
        case loading, table, empty, failed(SpreadsheetError)
    }

    let fileURL: URL
    let format: SpreadsheetFormat
    let limits: SpreadsheetLimits
    private let access: ScopedFileAccess
    let grid = SpreadsheetGridView()
    let noticeLabel = UILabel()
    private let noticeBar = UIView()
    let messageView = UIView()
    private let messageContent = UIContentUnavailableView(configuration: .empty())
    private let spinner = UIActivityIndicatorView(style: .medium)
    private(set) var tabBar: UIScrollView?
    private(set) var tabButtons: [UIButton] = []
    private let stack = UIStackView()
    private(set) var state: State = .loading
    private(set) var selectedSheet = 0
    private var workbook: Workbook?
    var cachedSheetCount: Int { tables.count }
    private var tables: [Int: SpreadsheetTable] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var loadGeneration = 0
    /// Edit as Text (CSV / TSV): the browser closes this viewer and opens
    /// the file in the editor.
    var onEditAsText: (() -> Void)?

    private let queue: DispatchQueue
    private let willReadSheet: (@Sendable (Int) -> Void)?

    init(url: URL, format: SpreadsheetFormat, access: ScopedFileAccess, limits: SpreadsheetLimits = .standard,
         queue: DispatchQueue = DispatchQueue(label: "owlink.spreadsheet", qos: .userInitiated),
         willReadSheet: (@Sendable (Int) -> Void)? = nil) {
        self.queue = queue
        self.willReadSheet = willReadSheet
        self.fileURL = url
        self.format = format
        self.access = access
        self.limits = limits
        super.init(nibName: nil, bundle: nil)
        DocumentViewers.configure(self, url: url, subtitle: DocumentViewers.subtitle(kind: format.kindName, url: url)) { [weak self] in
            self?.close()
        }
        var items = [DocumentViewers.shareItem(for: self, url: url)]
        if format.isText {
            let edit = UIBarButtonItem(title: String(localized: "Edit as Text"), image: UIImage(systemName: "square.and.pencil"),
                                       primaryAction: UIAction { [weak self] _ in self?.editAsText() })
            edit.accessibilityIdentifier = "viewer.editAsText"
            edit.accessibilityLabel = String(localized: "Edit as Text")
            items.append(edit)
        }
        navigationItem.rightBarButtonItems = items
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        noticeLabel.font = .preferredFont(forTextStyle: .footnote)
        noticeLabel.adjustsFontForContentSizeCategory = true
        noticeLabel.textColor = .secondaryLabel
        noticeLabel.numberOfLines = 0
        noticeLabel.textAlignment = .center
        noticeLabel.accessibilityIdentifier = "viewer.notice"
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false
        noticeBar.backgroundColor = .secondarySystemBackground
        noticeBar.addSubview(noticeLabel)
        NSLayoutConstraint.activate([
            noticeLabel.topAnchor.constraint(equalTo: noticeBar.topAnchor, constant: 6),
            noticeLabel.bottomAnchor.constraint(equalTo: noticeBar.bottomAnchor, constant: -6),
            noticeLabel.leadingAnchor.constraint(equalTo: noticeBar.layoutMarginsGuide.leadingAnchor),
            noticeLabel.trailingAnchor.constraint(equalTo: noticeBar.layoutMarginsGuide.trailingAnchor),
        ])
        noticeBar.isHidden = true
        noticeLabel.isHidden = true

        stack.addArrangedSubview(noticeBar)
        stack.addArrangedSubview(grid)
        grid.isHidden = true

        messageView.translatesAutoresizingMaskIntoConstraints = false
        messageContent.translatesAutoresizingMaskIntoConstraints = false
        messageView.addSubview(messageContent)
        messageView.isHidden = true
        messageView.accessibilityIdentifier = "viewer.message"
        view.addSubview(messageView)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            messageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            messageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            messageView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            messageView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            messageContent.topAnchor.constraint(equalTo: messageView.topAnchor),
            messageContent.bottomAnchor.constraint(equalTo: messageView.bottomAnchor),
            messageContent.leadingAnchor.constraint(equalTo: messageView.leadingAnchor),
            messageContent.trailingAnchor.constraint(equalTo: messageView.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        load()
    }

    /// Returns once the sheet being loaded is shown (or failed).
    func loaded() async {
        if state != .loading { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func finishLoading(_ s: State) {
        state = s
        spinner.stopAnimating()
        let w = waiters
        waiters = []
        for c in w { c.resume() }
    }

    // MARK: Loading

    private func load() {
        state = .loading
        spinner.startAnimating()
        let url = fileURL, format = format, limits = limits
        loadGeneration += 1
        let gen = loadGeneration
        queue.async { [weak self] in
            let result: Result<(Workbook?, SpreadsheetTable), Error> = Result {
                if format == .xlsx {
                    let wb = try Workbook(url: url, limits: limits)
                    return (wb, try wb.table(at: 0, limits: limits))
                }
                return (nil, try DelimitedText.table(url: url, limits: limits))
            }
            DispatchQueue.main.async {
                guard let self, gen == self.loadGeneration else { return }
                switch result {
                case .success(let (wb, table)):
                    self.workbook = wb
                    self.tables[0] = table
                    if let wb, wb.sheets.count > 1 { self.makeTabs(wb.sheets) }
                    self.showTable(table)
                case .failure(let e):
                    self.showFailure(e)
                }
            }
        }
    }

    /// Shows sheet `index` of the workbook (read once, then kept).
    func selectSheet(_ index: Int) {
        guard let wb = workbook, index >= 0, index < wb.sheets.count, index != selectedSheet || state == .loading else { return }
        selectedSheet = index
        updateTabs()
        // A sheet still loading for another tab is no longer wanted.
        loadGeneration += 1
        if let t = tables[index] { showTable(t); return }
        state = .loading
        spinner.startAnimating()
        let gen = loadGeneration, limits = limits, willReadSheet = willReadSheet
        queue.async { [weak self] in
            willReadSheet?(index)
            let result = Result { try wb.table(at: index, limits: limits) }
            DispatchQueue.main.async {
                guard let self else { return }
                if case .success(let t) = result { self.tables[index] = t } // kept for a later tap
                guard gen == self.loadGeneration else { return }
                switch result {
                case .success(let t):
                    self.showTable(t)
                case .failure(let e):
                    self.showFailure(e)
                }
            }
        }
    }

    private func showTable(_ t: SpreadsheetTable) {
        let sheet = workbook.map { $0.sheets[selectedSheet] }
        var notes: [String] = []
        if sheet?.isHidden == true { notes.append(String(localized: "This sheet is hidden in the workbook.")) }
        if let n = t.truncationNotice { notes.append(n) }
        noticeLabel.text = notes.joined(separator: " ")
        noticeLabel.isHidden = notes.isEmpty
        noticeBar.isHidden = notes.isEmpty
        if t.isEmpty {
            var c = UIContentUnavailableConfiguration.empty()
            c.image = UIImage(systemName: sheet?.isChart == true ? "chart.bar" : "tablecells")
            c.text = sheet?.isChart == true ? String(localized: "Chart Sheet") : String(localized: "Empty Sheet")
            c.secondaryText = sheet?.isChart == true
                ? String(localized: "This sheet holds a chart, which Owlink can’t show.")
                : (workbook == nil ? String(localized: "This file has no rows.") : String(localized: "This sheet has no cells with values."))
            showMessage(c)
            grid.isHidden = true
            finishLoading(.empty)
            return
        }
        messageView.isHidden = true
        grid.isHidden = false
        view.layoutIfNeeded()
        grid.show(t)
        finishLoading(.table)
    }

    private func showFailure(_ error: Error) {
        let e = (error as? SpreadsheetError) ?? .notAWorkbook
        var c = UIContentUnavailableConfiguration.empty()
        switch e {
        case .passwordProtected:
            c.image = UIImage(systemName: "lock.fill")
            c.text = String(localized: "Password Protected")
            c.secondaryText = String(localized: "This workbook needs a password to open, and Owlink can’t open protected workbooks. Use Share to open it in another app.")
        case .notText:
            c.image = UIImage(systemName: "exclamationmark.triangle")
            c.text = String(localized: "Can’t Show This File")
            c.secondaryText = String(localized: "This doesn’t look like text. Use Share to open it in another app.")
        case .notAWorkbook, .damaged:
            c.image = UIImage(systemName: "exclamationmark.triangle")
            c.text = String(localized: "Can’t Open This Spreadsheet")
            c.secondaryText = String(localized: "The file is damaged or isn’t an Excel workbook. Use Share to open it in another app.")
        }
        noticeBar.isHidden = true
        noticeLabel.isHidden = true
        grid.isHidden = true
        showMessage(c)
        finishLoading(.failed(e))
    }

    private func showMessage(_ c: UIContentUnavailableConfiguration) {
        messageContent.configuration = c
        messageView.isHidden = false
        messageView.accessibilityLabel = [c.text, c.secondaryText].compactMap { $0 }.joined(separator: ". ")
    }

    // MARK: Tabs

    private func makeTabs(_ sheets: [Workbook.Sheet]) {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.accessibilityIdentifier = "viewer.sheetTabs"
        scroll.accessibilityTraits = .tabBar
        scroll.accessibilityLabel = String(localized: "Sheets")
        scroll.isAccessibilityElement = false
        scroll.shouldGroupAccessibilityChildren = true
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -16),
        ])
        tabButtons = sheets.enumerated().map { i, sheet in
            var c = UIButton.Configuration.gray()
            c.title = sheet.name
            c.cornerStyle = .capsule
            c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
                var a = a
                a.font = UIFont.preferredFont(forTextStyle: .subheadline)
                return a
            }
            let b = UIButton(configuration: c, primaryAction: UIAction { [weak self] _ in self?.selectSheet(i) })
            b.titleLabel?.adjustsFontForContentSizeCategory = true
            b.accessibilityIdentifier = "viewer.sheetTab.\(i)"
            b.accessibilityLabel = sheet.isHidden ? String(localized: "\(sheet.name), hidden") : sheet.name
            row.addArrangedSubview(b)
            return b
        }
        tabBar = scroll
        stack.insertArrangedSubview(scroll, at: 0)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        let fit = scroll.heightAnchor.constraint(equalTo: row.heightAnchor, constant: 16)
        fit.priority = .defaultHigh
        fit.isActive = true
        updateTabs()
    }

    private func updateTabs() {
        for (i, b) in tabButtons.enumerated() {
            let on = i == selectedSheet
            var c = on ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
            c.title = b.configuration?.title
            c.cornerStyle = .capsule
            c.titleTextAttributesTransformer = b.configuration?.titleTextAttributesTransformer
            b.configuration = c
            b.isSelected = on
            b.accessibilityTraits = on ? [.button, .selected] : [.button]
            if on { tabBar?.scrollRectToVisible(b.frame.insetBy(dx: -12, dy: 0), animated: false) }
        }
    }

    // MARK: Actions

    func editAsText() {
        onEditAsText?()
    }

    private func close() {
        dismiss(animated: true) { [access] in access.stop() }
    }

    func tearDown() { access.stop() }
}
