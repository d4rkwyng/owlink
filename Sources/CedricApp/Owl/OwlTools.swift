import AppKit
import CedricCore

/// Explain & tidy help (0.3.0), all offline and on demand: Explain Regex
/// and Decode Selection (JWT, base64, Unix time) on the selection, and
/// Find TODOs for the file. Reached from the owl's popover and Edit › Text
/// Tools; the result shows in a small popover by the selection (or the
/// owl). Nothing here runs unless asked.
extension EditorWindowController {
    var selectedTextForTools: String? {
        let r = textView.selectedRange()
        guard r.length > 0, r.length <= 64 * 1024 else { return nil }
        return (textView.string as NSString).substring(with: r)
    }

    var canExplainRegex: Bool { selectedTextForTools.map(RegexExplain.looksLikeRegex) ?? false }
    var canDecodeSelection: Bool { selectedTextForTools.flatMap { Decode.decode($0) } != nil }

    func explainRegexSelection() {
        guard let s = selectedTextForTools, RegexExplain.looksLikeRegex(s) else { NSSound.beep(); return }
        let e = RegexExplain.explain(s)
        showToolResult(title: String(localized: "Regex, explained"), body: e.text)
    }

    func decodeSelection() {
        guard let s = selectedTextForTools, let d = Decode.decode(s) else { NSSound.beep(); return }
        showToolResult(title: d.title, body: d.body)
    }

    /// The TODO, FIXME, HACK and XXX notes of the file, in a list to jump from.
    func showTodos() {
        let text = textView.string
        let language = doc.language.rawValue
        guard (text as NSString).length <= 4_000_000 else { NSSound.beep(); return }
        // Off the main thread (a long file's lexing pass), on a copy of the text.
        let generation = doc.changeCount
        Task { @MainActor [weak self] in
            let items = await Task.detached(priority: .userInitiated) { Todos.find(text, language: language) }.value
            // Still the same text: the lines listed are the lines there.
            guard let self, self.doc.changeCount == generation else { return }
            let vc = TodoListController(items: items) { [weak self] item in
                self?.goToLine(item.line)
            }
            self.showToolPopover(vc)
        }
    }

    func showToolResult(title: String, body: String) {
        showToolPopover(ToolResultController(title: title, body: body))
    }

    private func showToolPopover(_ vc: NSViewController) {
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = vc
        // By the selection when it's on screen, else by the owl, else the text's top.
        let sel = textView.selectedRange()
        var anchor = NSRect(x: textView.visibleRect.midX, y: textView.visibleRect.minY + 20, width: 1, height: 1)
        if sel.length > 0 || sel.location > 0 {
            let screen = textView.firstRect(forCharacterRange: sel, actualRange: nil)
            if let w = textView.window, screen != .zero {
                let inWindow = w.convertFromScreen(screen)
                let r = textView.convert(inWindow, from: nil)
                if textView.visibleRect.intersects(r) { anchor = r }
            }
        }
        if let owl, anchor == .zero { p.show(relativeTo: owl.overlay.bounds, of: owl.overlay, preferredEdge: .maxY); return }
        p.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
    }
}

/// A title and a read-only monospaced text, with Copy.
final class ToolResultController: NSViewController {
    let titleText: String
    let body: String

    init(title: String, body: String) {
        titleText = title
        self.body = body
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let head = NSTextField(labelWithString: titleText)
        head.font = .systemFont(ofSize: 12, weight: .semibold)
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.string = body
        tv.textContainerInset = NSSize(width: 2, height: 4)
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let lines = max(1, body.split(separator: "\n", omittingEmptySubsequences: false).count)
        let height = min(360, CGFloat(lines) * 15 + 12)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 420).isActive = true
        tv.frame = NSRect(x: 0, y: 0, width: 420, height: height)
        tv.autoresizingMask = [.width]
        let copy = NSButton(title: String(localized: "Copy"), target: self, action: #selector(copyBody))
        copy.controlSize = .small
        let stack = NSStackView(views: [head, scroll, copy])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        view = stack
    }

    @objc func copyBody() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }
}

/// Find TODOs: one row per note ("12  TODO  the note"); a click jumps there.
final class TodoListController: NSViewController {
    let items: [Todos.Item]
    let jump: (Todos.Item) -> Void

    init(items: [Todos.Item], jump: @escaping (Todos.Item) -> Void) {
        self.items = items
        self.jump = jump
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let head = NSTextField(labelWithString: items.isEmpty ? String(localized: "No TODOs in this file.")
                                   : String(localized: "TODOs in this file: \(items.count)"))
        head.font = .systemFont(ofSize: 12, weight: .semibold)
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        for (k, item) in items.prefix(500).enumerated() {
            let b = NSButton(title: String(localized: "\(item.line)  \(item.tag)  \(item.text)"), target: self, action: #selector(pick(_:)))
            b.isBordered = false
            b.alignment = .left
            b.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            b.lineBreakMode = .byTruncatingTail
            b.tag = k
            b.widthAnchor.constraint(lessThanOrEqualToConstant: 440).isActive = true
            list.addArrangedSubview(b)
        }
        let stack = NSStackView(views: [head])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        if !items.isEmpty {
            let scroll = NSScrollView()
            let clip = FlippedView()
            clip.addSubview(list)
            list.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([list.leadingAnchor.constraint(equalTo: clip.leadingAnchor), list.topAnchor.constraint(equalTo: clip.topAnchor),
                                         list.trailingAnchor.constraint(equalTo: clip.trailingAnchor)])
            let size = list.fittingSize
            clip.frame = NSRect(x: 0, y: 0, width: max(size.width, 300), height: size.height)
            scroll.documentView = clip
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.heightAnchor.constraint(equalToConstant: min(360, size.height + 4)).isActive = true
            scroll.widthAnchor.constraint(equalToConstant: min(460, max(size.width, 300) + 16)).isActive = true
            stack.addArrangedSubview(scroll)
        }
        view = stack
    }

    @objc func pick(_ sender: NSButton) {
        guard sender.tag < items.count else { return }
        jump(items[sender.tag])
        view.window?.close()
    }

    final class FlippedView: NSView { override var isFlipped: Bool { true } }
}
