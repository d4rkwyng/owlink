import AppKit
import CedricCore

/// One row of the Find in Files results: a file (its matches below it), a
/// match, or, in the replace preview, the "Skipped" group and its files.
@MainActor
final class ResultNode: NSObject {
    enum Kind { case file, match, skippedGroup, skipped }
    let kind: Kind
    let url: URL?
    let relativePath: String
    var children: [ResultNode] = []
    weak var parent: ResultNode?
    /// A match row in find mode.
    var result: FileSearchResult?
    /// A match row in the replace preview.
    var edit: ReplaceEdit?
    /// The replace preview: the file's index in the plan.
    var fileIndex = -1
    var skip: ReplaceSkip?
    var checked = true

    init(_ kind: Kind, url: URL?, relativePath: String) {
        self.kind = kind
        self.url = url
        self.relativePath = relativePath
    }

    /// A file row's box: on, off or mixed from its matches.
    var fileState: NSControl.StateValue {
        let on = children.filter(\.checked).count
        return on == 0 ? .off : on == children.count ? .on : .mixed
    }
}

/// Find in Files (⇧⌘F) and Replace in Files (⌥⇧⌘F): a side panel docked
/// at the right of the selected tab. The search runs on a background
/// queue (`FileSearch`); results stream into a two-level list (file, then
/// `line: text`); clicking a match opens the file at that line.
///
/// Replace mode adds a Replace field and **Preview Replace…**, which plans
/// the replace off the main thread (`FileReplace.plan`) and turns the list
/// into a preview: a box per file and per match (`before → after`), the
/// skipped files listed with why. **Replace All** acts on the checked
/// matches only (`onReplace`); **Undo Replace** puts the last one back.
/// Nothing here costs anything until the panel is first opened.
@MainActor
final class FindInFilesPanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    let queryField = NSTextField()
    let replaceField = NSTextField()
    let folderField = NSTextField()
    let includeField = NSTextField()
    let excludeField = NSTextField()
    let regexBox = NSButton(checkboxWithTitle: String(localized: "Regex"), target: nil, action: nil)
    let caseBox = NSButton(checkboxWithTitle: String(localized: "Match Case"), target: nil, action: nil)
    let replaceBox = NSButton(checkboxWithTitle: String(localized: "Replace"), target: nil, action: nil)
    let gitIgnoreBox = NSButton(checkboxWithTitle: String(localized: "Respect .gitignore"), target: nil, action: nil)
    let findButton = NSButton(title: String(localized: "Find"), target: nil, action: nil)
    let stopButton = NSButton(title: String(localized: "Stop"), target: nil, action: nil)
    let previewButton = NSButton(title: String(localized: "Preview Replace…"), target: nil, action: nil)
    let replaceAllButton = NSButton(title: String(localized: "Replace All"), target: nil, action: nil)
    let cancelPreviewButton = NSButton(title: String(localized: "Cancel"), target: nil, action: nil)
    let undoButton = NSButton(title: String(localized: "Undo Replace in Files"), target: nil, action: nil)
    /// Replace All's progress while the files are written.
    let writeProgress = NSProgressIndicator()
    let status = NSTextField(labelWithString: "")
    /// The replace preview's summary (and the result of a replace or undo).
    let summary = NSTextField(wrappingLabelWithString: "")
    let table = NSOutlineView()
    private let tableScroll = NSScrollView()
    private var replaceRow: NSView!
    private var replaceButtons: NSView!

    var isShown = false
    var onOpen: ((FileSearchResult) -> Void)?
    var onClose: (() -> Void)?
    /// Replace All: the plan with only the checked matches, a progress
    /// callback and a completion with what to show (the disk writes run
    /// off the main thread; both callbacks come on the main thread).
    var onReplace: ((ReplacePlan, @escaping @MainActor (ReplaceProgress) -> Void, @escaping @MainActor (String) -> Void) -> Void)?
    /// Called when a Replace All has finished (the check waits on it).
    var onReplaced: (() -> Void)?
    /// Replace All (or Undo Replace) is writing: the preview stays, every control is off.
    private(set) var replacing = false
    /// Undo Replace: a progress callback and a completion with what to
    /// show (the disk files are restored off the main thread; both
    /// callbacks come on the main thread).
    var onUndo: ((@escaping @MainActor (ReplaceProgress) -> Void, @escaping @MainActor (String) -> Void) -> Void)?
    /// Whether there is a replace to undo.
    var canUndo: (() -> Bool)?
    /// The text of files open in a tab, by standardized path, for these files.
    var buffers: (([URL]) -> [String: OpenBuffer])?
    private(set) var results: [FileSearchResult] = []
    private(set) var nodes: [ResultNode] = []
    private(set) var running: FileSearch?
    private(set) var lastSummary: FileSearchSummary?
    /// The options of the search `results` came from.
    private(set) var lastOptions: FileSearchOptions?
    /// Called when a search finishes (the in-process check waits on it).
    var onFinished: (() -> Void)?
    /// Called when a preview is ready (or failed).
    var onPreviewReady: (() -> Void)?
    /// The replace preview, while it is shown.
    private(set) var plan: ReplacePlan?
    private var planning: PlanJob?
    var previewing: Bool { plan != nil }

    final class PlanJob: @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelled = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 600))
        clipsToBounds = true
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        // Since macOS 14 views don't clip to their bounds and dirtyRect
        // can be the whole window: fill only our own part.
        dirtyRect.intersection(bounds).fill()
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        l.widthAnchor.constraint(equalToConstant: 56).isActive = true
        return l
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 6
        s.alignment = .centerY
        return s
    }

    private func build() {
        let title = NSTextField(labelWithString: String(localized: "Find in Files"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let close = NSButton(title: "", image: NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close"))!,
                             target: self, action: #selector(closePanel))
        close.isBordered = false
        let chooser = NSButton(title: String(localized: "Choose…"), target: self, action: #selector(chooseFolder))
        chooser.controlSize = .small
        for f in [queryField, replaceField, folderField, includeField, excludeField] {
            f.controlSize = .small
            f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            f.lineBreakMode = .byTruncatingHead
            f.cell?.isScrollable = true
            f.target = self
            f.action = #selector(startSearch)
            f.setContentHuggingPriority(.defaultLow, for: .horizontal)
            // Typing re-validates the buttons (Preview Replace… needs a query).
            f.delegate = self
        }
        replaceField.action = #selector(previewReplace)
        queryField.placeholderString = String(localized: "Text or regular expression")
        replaceField.placeholderString = String(localized: "Replacement ($1 for a regex group)")
        includeField.placeholderString = String(localized: "All files (e.g. *.swift, *.md)")
        excludeField.stringValue = FileSearchOptions.defaultExclude.joined(separator: ", ")
        for b in [regexBox, caseBox, replaceBox, gitIgnoreBox] { b.controlSize = .small; b.font = .systemFont(ofSize: NSFont.smallSystemFontSize) }
        gitIgnoreBox.state = .on
        gitIgnoreBox.toolTip = String(localized: "Skip what the folder’s .gitignore files and .git/info/exclude ignore")
        replaceBox.target = self; replaceBox.action = #selector(replaceToggled)
        findButton.target = self; findButton.action = #selector(startSearch)
        stopButton.target = self; stopButton.action = #selector(stopSearch)
        previewButton.target = self; previewButton.action = #selector(previewReplace)
        replaceAllButton.target = self; replaceAllButton.action = #selector(replaceAll)
        cancelPreviewButton.target = self; cancelPreviewButton.action = #selector(cancelPreview)
        undoButton.target = self; undoButton.action = #selector(undoReplace)
        stopButton.isEnabled = false
        for b in [findButton, stopButton, previewButton, replaceAllButton, cancelPreviewButton, undoButton] {
            b.controlSize = .small; b.bezelStyle = .rounded
        }
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .labelColor
        summary.isHidden = true
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        replaceRow = row([label(String(localized: "Replace")), replaceField])
        writeProgress.style = .bar
        writeProgress.controlSize = .small
        writeProgress.isIndeterminate = false
        writeProgress.minValue = 0
        writeProgress.isHidden = true
        writeProgress.widthAnchor.constraint(equalToConstant: 90).isActive = true
        replaceButtons = row([label(""), previewButton, replaceAllButton, cancelPreviewButton, undoButton, writeProgress])
        let form = NSStackView(views: [
            row([title, spacer, close]),
            row([label(String(localized: "Find")), queryField]),
            replaceRow,
            row([label(""), regexBox, caseBox, replaceBox]),
            row([label(String(localized: "Folder")), folderField, chooser]),
            row([label(String(localized: "Include")), includeField]),
            row([label(String(localized: "Exclude")), excludeField]),
            row([label(""), gitIgnoreBox]),
            row([label(""), findButton, stopButton, status]),
            replaceButtons,
            summary,
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        form.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        for v in form.arrangedSubviews { v.trailingAnchor.constraint(equalTo: form.trailingAnchor, constant: -8).isActive = true }

        let col = NSTableColumn(identifier: .init("result"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.outlineTableColumn = col
        table.headerView = nil
        table.rowHeight = 18
        table.style = .plain
        table.indentationPerLevel = 12
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = false
        tableScroll.borderType = .noBorder

        let stack = NSStackView(views: [form, tableScroll])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        tableScroll.setContentHuggingPriority(.init(1), for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
        updateReplaceControls()
    }

    // MARK: Replace mode

    var replaceMode: Bool {
        get { replaceBox.state == .on }
        set { replaceBox.state = newValue ? .on : .off; updateReplaceControls() }
    }

    @objc func replaceToggled() {
        if !replaceMode { cancelPreview() }
        updateReplaceControls()
    }

    /// Shows the replace row and buttons in replace mode; enables what applies now.
    func updateReplaceControls() {
        let on = replaceMode
        replaceRow.isHidden = !on
        replaceButtons.isHidden = !on
        let idle = running == nil && planning == nil
        let capped = lastSummary?.truncated == true
        previewButton.isHidden = previewing
        previewButton.isEnabled = idle && !queryField.stringValue.isEmpty && !replacing
        replaceAllButton.isHidden = !previewing
        cancelPreviewButton.isHidden = !previewing
        replaceAllButton.isEnabled = previewing && !capped && checkedCount > 0 && !replacing
        cancelPreviewButton.isEnabled = !replacing
        undoButton.isHidden = !(canUndo?() ?? false) || previewing || replacing
        writeProgress.isHidden = !replacing
        summary.isHidden = !on || summary.stringValue.isEmpty
        // A preview is tied to the fields it was made from; an undo under way locks them too.
        for f in [queryField, replaceField, folderField, includeField, excludeField] { f.isEnabled = !previewing && !replacing }
        for b in [regexBox, caseBox, gitIgnoreBox, findButton] { b.isEnabled = !previewing && !replacing }
        replaceBox.isEnabled = !replacing
    }

    func controlTextDidChange(_ obj: Notification) {
        updateReplaceControls()
    }

    /// The options the fields describe now.
    func currentOptions() -> FileSearchOptions? {
        let path = (folderField.stringValue as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return FileSearchOptions(root: URL(fileURLWithPath: path), query: queryField.stringValue,
                                 regex: regexBox.state == .on, caseSensitive: caseBox.state == .on,
                                 include: FileSearchOptions.globs(includeField.stringValue),
                                 exclude: FileSearchOptions.globs(excludeField.stringValue),
                                 respectGitIgnore: gitIgnoreBox.state == .on)
    }

    static func same(_ a: FileSearchOptions?, _ b: FileSearchOptions?) -> Bool {
        guard let a, let b else { return false }
        return a.root.standardizedFileURL == b.root.standardizedFileURL && a.query == b.query && a.regex == b.regex
            && a.caseSensitive == b.caseSensitive && a.include == b.include && a.exclude == b.exclude
            && a.respectGitIgnore == b.respectGitIgnore
    }

    /// Preview Replace…: searches first if the fields changed since the
    /// last search, then plans the replace off the main thread.
    @objc func previewReplace() {
        guard replaceMode, !previewing, planning == nil else { return }
        guard !queryField.stringValue.isEmpty else { status.stringValue = String(localized: "Type something to find."); return }
        if running != nil { return }
        guard Self.same(lastOptions, currentOptions()), lastSummary != nil, lastSummary?.cancelled != true else {
            let previous = onFinished
            onFinished = { [weak self] in
                self?.onFinished = previous
                previous?()
                if self?.lastSummary != nil { self?.previewReplace() } else { self?.onPreviewReady?() }
            }
            startSearch()
            return
        }
        if lastSummary?.truncated == true {
            summary.stringValue = String(localized: "Too many matches: narrow the search.")
            updateReplaceControls()
            onPreviewReady?()
            return
        }
        guard let root = lastOptions?.root, !results.isEmpty else {
            summary.stringValue = String(localized: "Nothing to replace.")
            updateReplaceControls()
            onPreviewReady?()
            return
        }
        var seen = Set<URL>()
        var candidates: [FileReplace.Candidate] = []
        for r in results where seen.insert(r.url).inserted {
            candidates.append(.init(url: r.url, relativePath: r.relativePath, searchStamp: r.stamp))
        }
        let searchSkipped = lastSummary?.skippedFiles ?? []
        let query = ReplaceQuery(query: queryField.stringValue, template: replaceField.stringValue,
                                 regex: regexBox.state == .on, caseSensitive: caseBox.state == .on)
        let bufs = buffers?(candidates.map(\.url)) ?? [:]
        let job = PlanJob()
        planning = job
        status.stringValue = String(localized: "Preparing preview…")
        updateReplaceControls()
        let me = WeakRef(self)
        let input = MainBox(value: (candidates, bufs))
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try FileReplace.plan(query, root: root, candidates: input.value.0, buffers: input.value.1,
                                                  isCancelled: { job.cancelled }) }
            let out = MainBox(value: r)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let p = me.value, p.planning === job else { return }
                    p.planning = nil
                    switch out.value {
                    case .success(let plan) where !plan.cancelled:
                        p.showPreview(plan, searchSkipped: searchSkipped)
                    case .success:
                        p.status.stringValue = String(localized: "stopped")
                    case .failure(let e):
                        p.status.stringValue = e.localizedDescription
                    }
                    p.updateReplaceControls()
                    p.onPreviewReady?()
                }
            }
        }
    }

    /// Every file left out of the preview, with why: the search's (binary,
    /// over 20 MB) and the plan's (mixed line endings, …), in path order.
    /// The summary counts this same list.
    private(set) var skippedFiles: [SkippedFile] = []

    func showPreview(_ plan: ReplacePlan, searchSkipped: [SkippedFile]) {
        self.plan = plan
        skippedFiles = (searchSkipped + plan.skipped).sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        var out: [ResultNode] = []
        for (k, f) in plan.files.enumerated() {
            let file = ResultNode(.file, url: f.url, relativePath: f.relativePath)
            file.fileIndex = k
            file.children = f.edits.map { e in
                let n = ResultNode(.match, url: f.url, relativePath: f.relativePath)
                n.edit = e
                n.fileIndex = k
                n.parent = file
                return n
            }
            out.append(file)
        }
        if !skippedFiles.isEmpty {
            let g = ResultNode(.skippedGroup, url: nil, relativePath: String(localized: "Skipped (\(skippedFiles.count))"))
            g.children = skippedFiles.map { s in
                let n = ResultNode(.skipped, url: s.url, relativePath: s.relativePath)
                n.skip = s.reason
                n.parent = g
                return n
            }
            out.append(g)
        }
        nodes = out
        table.reloadData()
        table.expandItem(nil, expandChildren: true)
        refreshSummary()
        status.stringValue = String(localized: "Preview: nothing is changed until Replace All.")
    }

    var checkedCount: Int {
        nodes.filter { $0.kind == .file }.reduce(0) { $0 + $1.children.filter(\.checked).count }
    }

    /// "N replacements in M files. Skipped: x binary, …".
    func refreshSummary() {
        guard let plan else { return }
        let files = nodes.filter { $0.kind == .file && $0.children.contains(where: \.checked) }.count
        let n = checkedCount
        var s = n == 1 ? String(localized: "1 replacement in \(files) file.") : String(localized: "\(n) replacements in \(files) files.")
        if n != plan.replacementCount { s += " " + String(localized: "(\(plan.replacementCount - n) unchecked)") }
        var skipped: [String] = []
        func count(_ r: ReplaceSkip) -> Int { skippedFiles.filter { $0.reason == r }.count }
        let binary = count(.binary), large = count(.tooLarge)
        if binary > 0 { skipped.append(String(localized: "\(binary) binary")) }
        if large > 0 { skipped.append(String(localized: "\(large) over 20 MB")) }
        for r in ReplaceSkip.allCases where r != .binary && r != .tooLarge {
            let c = count(r)
            if c > 0 { skipped.append("\(c) \(r.summary)") }
        }
        if !skipped.isEmpty { s += " " + String(localized: "Skipped: \(skipped.joined(separator: ", ")).") }
        summary.stringValue = s
        summary.toolTip = s
        updateReplaceControls()
    }

    /// The plan with only the checked matches.
    func checkedPlan() -> ReplacePlan? {
        guard var p = plan else { return nil }
        var files: [ReplaceFile] = []
        for node in nodes where node.kind == .file {
            var f = p.files[node.fileIndex]
            f.edits = node.children.filter(\.checked).compactMap(\.edit)
            if !f.edits.isEmpty { files.append(f) }
        }
        p.files = files
        return p
    }

    @objc func replaceAll() {
        guard previewing, !replacing, lastSummary?.truncated != true, let p = checkedPlan(), !p.files.isEmpty, let onReplace else {
            NSSound.beep(); return
        }
        replacing = true
        writeProgress.doubleValue = 0
        status.stringValue = String(localized: "Replacing…")
        updateReplaceControls()
        onReplace(p, { [weak self] progress in self?.showProgress(progress) }, { [weak self] message in
            guard let self else { return }
            self.replacing = false
            self.endPreview()
            self.status.stringValue = String(localized: "Replaced.")
            self.showOutcome(message)
            self.onReplaced?()
        })
    }

    /// "Writing 3 of 40 files…" and the bar, while Replace All writes.
    func showProgress(_ p: ReplaceProgress) {
        guard replacing else { return }
        switch p.stage {
        case .checking: status.stringValue = String(localized: "Checking \(p.done) of \(p.total) files…")
        case .backingUp: status.stringValue = String(localized: "Backing up \(p.done) of \(p.total) files…")
        case .writing: status.stringValue = String(localized: "Writing \(p.done) of \(p.total) files…")
        case .restoring:
            status.stringValue = String(localized: "Restoring \(p.done) of \(p.total) files…")
            // Undo: one stage, the whole bar.
            writeProgress.maxValue = 1
            writeProgress.doubleValue = p.total > 0 ? Double(p.done) / Double(p.total) : 1
            return
        }
        // Checking, backing up and writing each take a third of the bar.
        let stage: Double = p.stage == .checking ? 0 : p.stage == .backingUp ? 1 : 2
        writeProgress.maxValue = 3
        writeProgress.doubleValue = stage + (p.total > 0 ? Double(p.done) / Double(p.total) : 1)
    }

    /// Undo Replace: the panel is locked and shows progress while the
    /// files are restored, as for Replace All.
    @objc func undoReplace() {
        guard !replacing, let onUndo else { NSSound.beep(); return }
        replacing = true
        writeProgress.doubleValue = 0
        status.stringValue = String(localized: "Undoing…")
        updateReplaceControls()
        onUndo({ [weak self] progress in self?.showProgress(progress) }, { [weak self] message in
            guard let self else { return }
            self.replacing = false
            self.status.stringValue = message.isEmpty ? "" : String(localized: "Undone.")
            self.showOutcome(message)
        })
    }

    /// After Replace All or an undo: `message` in the summary, and the
    /// results searched again, so the list shows the files as they are now
    /// (not the matches from before the replace).
    func showOutcome(_ message: String) {
        if !previewing, !replacing, lastOptions != nil || !results.isEmpty {
            search(keepSummary: true)
        }
        summary.stringValue = message
        updateReplaceControls()
    }

    @objc func cancelPreview() {
        // The files being written stay the preview's until the writes land.
        guard !replacing else { NSSound.beep(); return }
        planning?.cancel()
        planning = nil
        guard previewing else { updateReplaceControls(); return }
        endPreview()
        summary.stringValue = ""
        updateReplaceControls()
    }

    /// Back to the search results.
    private func endPreview() {
        plan = nil
        nodes = Self.group(results)
        table.reloadData()
        table.expandItem(nil, expandChildren: true)
    }

    @objc func toggleChecked(_ sender: NSButton) {
        let row = table.row(for: sender)
        guard row >= 0, let node = table.item(atRow: row) as? ResultNode else { return }
        setChecked(node, sender.state != .off)
    }

    /// Checks or unchecks a match, or a file with all its matches.
    func setChecked(_ node: ResultNode, _ on: Bool) {
        guard !replacing else { table.reloadItem(node, reloadChildren: true); return }
        switch node.kind {
        case .file:
            node.children.forEach { $0.checked = on }
            table.reloadItem(node, reloadChildren: true)
        case .match:
            node.checked = on
            if let p = node.parent { table.reloadItem(p, reloadChildren: false) }
            table.reloadItem(node)
        default: return
        }
        refreshSummary()
    }

    // MARK: Search

    @objc func chooseFolder() {
        guard !previewing else { NSSound.beep(); return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = URL(fileURLWithPath: (folderField.stringValue as NSString).expandingTildeInPath)
        guard let w = window else { return }
        p.beginSheetModal(for: w) { [weak self] r in
            if r == .OK, let u = p.url { self?.folderField.stringValue = u.path }
        }
    }

    @objc func startSearch() { search(keepSummary: false) }

    func search(keepSummary: Bool) {
        if previewing || replacing { return }
        cancel()
        results = []
        nodes = []
        lastSummary = nil
        lastOptions = nil
        if !keepSummary { summary.stringValue = "" }
        table.reloadData()
        guard !queryField.stringValue.isEmpty else {
            status.stringValue = String(localized: "Type something to find.")
            updateReplaceControls()
            onFinished?()
            return
        }
        guard let o = currentOptions() else {
            status.stringValue = String(localized: "No such folder.")
            updateReplaceControls()
            onFinished?()
            return
        }
        let search = FileSearch(o)
        running = search
        lastOptions = o
        stopButton.isEnabled = true
        status.stringValue = String(localized: "Searching…")
        updateReplaceControls()
        let me = WeakRef(self)
        search.start(batch: { b in
            MainActor.assumeIsolated {
                guard let p = me.value, p.running === search else { return }
                p.append(b)
            }
        }, done: { r in
            MainActor.assumeIsolated {
                guard let p = me.value, p.running === search else { return }
                p.finished(r)
            }
        })
    }

    @objc func stopSearch() {
        running?.cancel()
    }

    func cancel() {
        running?.cancel()
        running = nil
        planning?.cancel()
        planning = nil
        stopButton.isEnabled = false
    }

    /// File rows with their match rows, in result order.
    static func group(_ rs: [FileSearchResult]) -> [ResultNode] {
        var out: [ResultNode] = []
        for r in rs { add(r, to: &out) }
        return out
    }

    @discardableResult
    private static func add(_ r: FileSearchResult, to nodes: inout [ResultNode]) -> (ResultNode, Bool) {
        var isNew = false
        let file: ResultNode
        if let last = nodes.last, last.url == r.url {
            file = last
        } else {
            file = ResultNode(.file, url: r.url, relativePath: r.relativePath)
            nodes.append(file)
            isNew = true
        }
        let m = ResultNode(.match, url: r.url, relativePath: r.relativePath)
        m.result = r
        m.parent = file
        file.children.append(m)
        return (file, isNew)
    }

    private func append(_ b: [FileSearchResult]) {
        results += b
        // Results come sorted by file: a batch continues the last file, then adds new ones.
        let oldCount = nodes.count
        let last = nodes.last
        let lastChildren = last?.children.count ?? 0
        for r in b { Self.add(r, to: &nodes) }
        table.beginUpdates()
        if let last, last.children.count > lastChildren {
            table.insertItems(at: IndexSet(lastChildren..<last.children.count), inParent: last, withAnimation: [])
        }
        if nodes.count > oldCount { table.insertItems(at: IndexSet(oldCount..<nodes.count), inParent: nil, withAnimation: []) }
        table.endUpdates()
        if let last, last.children.count > lastChildren { table.reloadItem(last) }
        for f in nodes[oldCount...] { table.expandItem(f) }
        status.stringValue = String(localized: "Searching… \(results.count) matching lines")
    }

    private func finished(_ r: Result<FileSearchSummary, Error>) {
        running = nil
        stopButton.isEnabled = false
        switch r {
        case .success(let s):
            lastSummary = s
            var parts = [s.results == 1 ? String(localized: "1 line") : String(localized: "\(s.results) lines"),
                         String(localized: "in \(s.filesMatched) of \(s.filesSearched) files")]
            if s.truncated { parts.append(String(localized: "stopped at \(s.results)")) }
            if s.cancelled { parts.append(String(localized: "stopped")) }
            if s.skippedBinary > 0 { parts.append(String(localized: "\(s.skippedBinary) binary skipped")) }
            if s.skippedLarge > 0 { parts.append(String(localized: "\(s.skippedLarge) over 20 MB skipped")) }
            status.stringValue = parts.joined(separator: ", ")
            status.toolTip = status.stringValue
            if s.truncated, replaceMode { summary.stringValue = String(localized: "Too many matches: narrow the search.") }
        case .failure(let e):
            lastOptions = nil
            if case FindEngine.FindError.invalidPattern = e {
                status.stringValue = String(localized: "Invalid regular expression")
            } else {
                status.stringValue = e.localizedDescription
            }
        }
        updateReplaceControls()
        onFinished?()
    }

    @objc func closePanel() { onClose?() }

    @objc func rowClicked() {
        trace("find in files: clicked row \(table.clickedRow)")
        let r = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard r >= 0, let node = table.item(atRow: r) as? ResultNode else { return }
        let target: FileSearchResult?
        switch node.kind {
        case .match:
            if let res = node.result {
                target = res
            } else if let e = node.edit, let url = node.url {
                target = FileSearchResult(url: url, relativePath: node.relativePath, line: e.line, column: e.lineRange.location + 1,
                                          text: e.lineText, ranges: [e.lineRange])
            } else {
                target = nil
            }
        case .file:
            target = node.children.first?.result
        default:
            target = nil
        }
        guard let target else { return }
        // After the click finishes: opening may move this panel to another tab.
        DispatchQueue.main.async { [weak self] in self?.onOpen?(target) }
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let n = item as? ResultNode else { return nodes.count }
        return n.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let n = item as? ResultNode else { return nodes[index] }
        return n.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ResultNode).map { !$0.children.isEmpty } ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ResultNode else { return nil }
        let checkable = previewing && (node.kind == .file || node.kind == .match)
        let id = NSUserInterfaceItemIdentifier(checkable ? "check" : "cell")
        let cell: ResultCell
        if let c = outlineView.makeView(withIdentifier: id, owner: self) as? ResultCell {
            cell = c
        } else {
            cell = ResultCell(checkable: checkable)
            cell.identifier = id
            cell.box?.target = self
            cell.box?.action = #selector(toggleChecked(_:))
        }
        if let box = cell.box {
            box.allowsMixedState = node.kind == .file
            box.state = node.kind == .file ? node.fileState : (node.checked ? .on : .off)
        }
        cell.label.attributedStringValue = Self.oneLine(Self.format(node))
        cell.label.toolTip = node.url.map { u in node.result.map { "\(u.path):\($0.line)" } ?? node.edit.map { "\(u.path):\($0.line)" } ?? u.path }
            ?? node.relativePath
        return cell
    }

    static var mono: NSFont { NSFont.monospacedSystemFont(ofSize: 11, weight: .regular) }

    /// One line, cut at the end: an attributed string's own paragraph
    /// style wraps (a long skipped path wrapped onto the row below).
    static func oneLine(_ s: NSAttributedString) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: s)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return out
    }

    static func format(_ node: ResultNode) -> NSAttributedString {
        switch node.kind {
        case .file:
            let out = NSMutableAttributedString(string: node.relativePath, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                                                        .foregroundColor: NSColor.labelColor])
            out.append(NSAttributedString(string: "  \(node.children.count)", attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                                          .foregroundColor: NSColor.secondaryLabelColor]))
            return out
        case .match:
            if let r = node.result { return format(r, withPath: false) }
            if let e = node.edit { return formatEdit(e) }
            return NSAttributedString()
        case .skippedGroup:
            return NSAttributedString(string: node.relativePath, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                                             .foregroundColor: NSColor.secondaryLabelColor])
        case .skipped:
            let out = NSMutableAttributedString(string: node.relativePath, attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
            out.append(NSAttributedString(string: " · \(node.skip?.summary ?? "")", attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                                                                .foregroundColor: NSColor.secondaryLabelColor]))
            return out
        }
    }

    /// `line: text` (with `path:` first if asked), matches in bold on a highlight.
    static func format(_ r: FileSearchResult, withPath: Bool = true) -> NSAttributedString {
        let out = NSMutableAttributedString(string: withPath ? "\(r.relativePath):\(r.line): " : "\(r.line): ",
                                            attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor])
        let text = r.text.replacingOccurrences(of: "\t", with: " ")
        let lead = text.prefix { $0 == " " }.utf16.count
        let body = NSMutableAttributedString(string: String(text.dropFirst(text.prefix { $0 == " " }.count)),
                                             attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
        for range in r.ranges {
            let shifted = NSRange(location: range.location - lead, length: range.length)
            guard shifted.location >= 0, NSMaxRange(shifted) <= body.length else { continue }
            body.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                                .backgroundColor: NSColor.findHighlightColor.withAlphaComponent(0.55),
                                .foregroundColor: NSColor.black], range: shifted)
        }
        out.append(body)
        return out
    }

    /// `line: before → after`: the match struck through, the replacement
    /// highlighted in its place.
    static func formatEdit(_ e: ReplaceEdit) -> NSAttributedString {
        let out = NSMutableAttributedString(string: "\(e.line): ", attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor])
        let ns = e.lineText.replacingOccurrences(of: "\t", with: " ") as NSString
        let r = NSRange(location: min(e.lineRange.location, ns.length), length: min(e.lineRange.length, max(0, ns.length - e.lineRange.location)))
        let head = ns.substring(to: r.location)
        let trimmed = head.drop { $0 == " " }
        out.append(NSAttributedString(string: String(trimmed), attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
        out.append(NSAttributedString(string: ns.substring(with: r), attributes: [
            .font: mono, .foregroundColor: NSColor.secondaryLabelColor,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .backgroundColor: NSColor.systemRed.withAlphaComponent(0.18),
        ]))
        out.append(NSAttributedString(string: e.replacement.replacingOccurrences(of: "\n", with: "⏎"), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.28),
        ]))
        out.append(NSAttributedString(string: ns.substring(from: NSMaxRange(r)), attributes: [.font: mono, .foregroundColor: NSColor.labelColor]))
        return out
    }
}

/// A results row: an optional check box (replace preview), then the text.
/// Clicks on the text go to the outline (one click opens the result).
final class ResultCell: NSTableCellView {
    let box: NSButton?
    let label = ResultLabel(labelWithString: "")

    init(checkable: Bool) {
        box = checkable ? NSButton(checkboxWithTitle: "", target: nil, action: nil) : nil
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.alignment = .natural
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        var cs = [label.trailingAnchor.constraint(equalTo: trailingAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor)]
        if let box {
            box.controlSize = .small
            box.imagePosition = .imageOnly
            box.setContentHuggingPriority(.required, for: .horizontal)
            box.translatesAutoresizingMaskIntoConstraints = false
            addSubview(box)
            cs += [box.leadingAnchor.constraint(equalTo: leadingAnchor), box.centerYAnchor.constraint(equalTo: centerYAnchor),
                   label.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 2)]
        } else {
            cs.append(label.leadingAnchor.constraint(equalTo: leadingAnchor))
        }
        NSLayoutConstraint.activate(cs)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// A result row's text: clicks go to the table (one click opens the result).
final class ResultLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
