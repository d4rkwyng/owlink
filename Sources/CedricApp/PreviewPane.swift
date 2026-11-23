import AppKit
import CedricCore

/// What draws a preview: the web view for Markdown and HTML
/// (PreviewController), the grid for CSV and TSV (CSVPreview).
@MainActor
protocol PreviewRenderer: AnyObject {
    var view: NSView { get }
    /// Shows `text`. `fileName` tells .tsv from .csv.
    func render(text: String, language: Language, palette: EditorPalette, baseURL: URL?, fileName: String?)
    /// Scrolls to roughly source line `line` (or `fraction` of the way down).
    func sync(line: Int, fraction: Double, language: Language)
    /// Whether this renderer draws `language`.
    func handles(_ language: Language) -> Bool
    /// The preview bar's zoom (1: as drawn).
    var zoom: Double { get set }
    /// Refresh: drop what is cached (the loaded page), so the next render is whole.
    func refresh()
}

extension PreviewRenderer {
    var zoom: Double { get { 1 } set {} }
    func refresh() {}
}

extension PreviewController: PreviewRenderer {
    var view: NSView { container }

    func render(text: String, language: Language, palette: EditorPalette, baseURL: URL?, fileName: String?) {
        renderHome(text: text, language: language, palette: palette, folder: baseURL)
    }

    func sync(line: Int, fraction: Double, language: Language) {
        sync(line: line, fraction: fraction, markdown: language == .markdown)
    }

    func handles(_ language: Language) -> Bool { language == .markdown || language == .html }

    var zoom: Double {
        get { Double(webView.pageZoom) }
        set { webView.pageZoom = CGFloat(newValue) }
    }

    func refresh() { forceReload() }
}

/// What the preview bar shows (the tab works it out after each change).
struct PreviewBarState: Equatable {
    var items: [PreviewBarItem] = []
    var syncScroll = true
    var zoom = 1.0
    var allowJavaScript = false
    var allowNetwork = false
    var detached = false
    var sorted = false
    var rowCount = ""
    var canGoBack = false
    var canGoForward = false
    var canGoHome = false
}

/// The quick-actions bar in the preview's header: SF Symbol buttons (with
/// tooltips and VoiceOver labels) for the items PreviewBarItem lists, laid
/// out from the right edge so a changing row count never moves them. Every
/// button keeps its size whatever its state: toggling never shifts the layout.
@MainActor
final class PreviewBar: NSView {
    private(set) var buttons: [PreviewBarItem: NSButton] = [:]
    let exportButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let rowLabel = NSTextField(labelWithString: "")
    private(set) var state = PreviewBarState()
    static let buttonSize = NSSize(width: 22, height: 20)
    static let gap: CGFloat = 2
    /// The tab's handler for a button.
    var onAction: ((PreviewBarItem) -> Void)?
    /// Export ▸ HTML (true) / PDF (false).
    var onExport: ((Bool) -> Void)?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        for item in PreviewBarItem.allCases where item != .rowCount && item != .export {
            let b = NSButton(title: "", target: self, action: #selector(pressed(_:)))
            b.bezelStyle = .recessed
            b.showsBorderOnlyWhileMouseInside = true
            b.controlSize = .small
            b.imagePosition = .imageOnly
            b.imageScaling = .scaleProportionallyDown
            if Self.isToggle(item) { b.setButtonType(.pushOnPushOff) }
            b.identifier = NSUserInterfaceItemIdentifier("previewbar.\(item.rawValue)")
            b.isHidden = true
            buttons[item] = b
            addSubview(b)
        }
        exportButton.isBordered = false
        exportButton.controlSize = .small
        (exportButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        head.image = Self.symbol("square.and.arrow.up", String(localized: "Export"))
        exportButton.menu?.addItem(head)
        let html = NSMenuItem(title: String(localized: "Export as HTML…"), action: #selector(exportHTML(_:)), keyEquivalent: "")
        let pdf = NSMenuItem(title: String(localized: "Export as PDF…"), action: #selector(exportPDF(_:)), keyEquivalent: "")
        for i in [html, pdf] { i.target = self; exportButton.menu?.addItem(i) }
        exportButton.toolTip = String(localized: "Export the Markdown as HTML or PDF")
        exportButton.setAccessibilityLabel(String(localized: "Export"))
        exportButton.identifier = NSUserInterfaceItemIdentifier("previewbar.export")
        exportButton.isHidden = true
        addSubview(exportButton)
        rowLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        rowLabel.textColor = .secondaryLabelColor
        rowLabel.lineBreakMode = .byTruncatingTail
        rowLabel.isHidden = true
        addSubview(rowLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    static func isToggle(_ item: PreviewBarItem) -> Bool { [.syncScroll, .allowJavaScript, .allowNetwork].contains(item) }

    static func symbol(_ name: String, _ label: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: label)
        return img?.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }

    /// The view for an item (the Export pull-down, the row count, or a button).
    func view(_ item: PreviewBarItem) -> NSView? {
        switch item {
        case .export: return exportButton
        case .rowCount: return rowLabel
        default: return buttons[item]
        }
    }

    /// Shows `s`; false (and nothing done) when it is what is shown already.
    @discardableResult
    func apply(_ s: PreviewBarState) -> Bool {
        guard s != state || buttons.values.allSatisfy({ $0.image == nil }) else { return false }
        let itemsChanged = s.items != state.items
        state = s
        for item in PreviewBarItem.allCases { view(item)?.isHidden = !s.items.contains(item) }
        for (item, b) in buttons {
            let (sym, label, tip, on) = Self.look(item, s)
            b.image = Self.symbol(sym, label)
            if b.image == nil { b.title = label; b.imagePosition = .noImage }
            b.toolTip = tip
            b.setAccessibilityLabel(label)
            if Self.isToggle(item) {
                b.state = on ? .on : .off
                b.contentTintColor = on ? .controlAccentColor : nil
            }
            switch item {
            case .zoomIn: b.isEnabled = PreviewZoom.canStep(s.zoom, in: true)
            case .zoomOut: b.isEnabled = PreviewZoom.canStep(s.zoom, in: false)
            case .sortReset: b.isEnabled = s.sorted
            case .back: b.isEnabled = s.canGoBack
            case .forward: b.isEnabled = s.canGoForward
            case .home: b.isEnabled = s.canGoHome
            default: b.isEnabled = true
            }
        }
        rowLabel.stringValue = s.rowCount
        rowLabel.setAccessibilityLabel(s.rowCount)
        if itemsChanged { needsLayout = true }
        layoutRowLabel()
        return true
    }

    /// Symbol, label, tooltip and on-state for an item.
    private static func look(_ item: PreviewBarItem, _ s: PreviewBarState) -> (String, String, String, Bool) {
        let pct = PreviewZoom.percent(s.zoom)
        switch item {
        case .back: return ("chevron.left", String(localized: "Back"), String(localized: "Back in preview"), false)
        case .forward: return ("chevron.right", String(localized: "Forward"), String(localized: "Forward in preview"), false)
        case .home: return ("house", String(localized: "This Document"), String(localized: "Return to this document"), false)
        case .refresh: return ("arrow.clockwise", String(localized: "Refresh"), String(localized: "Refresh the preview"), false)
        case .syncScroll:
            return ("arrow.up.arrow.down", String(localized: "Sync Scrolling"),
                    s.syncScroll ? String(localized: "Scrolling in step with the text (click to stop)")
                                 : String(localized: "Scroll the preview in step with the text"), s.syncScroll)
        case .zoomOut: return ("minus.magnifyingglass", String(localized: "Zoom Out"), String(localized: "Zoom out (now \(pct))"), false)
        case .zoomIn: return ("plus.magnifyingglass", String(localized: "Zoom In"), String(localized: "Zoom in (now \(pct))"), false)
        case .allowJavaScript:
            return ("curlybraces", String(localized: "Allow JavaScript"),
                    s.allowJavaScript ? String(localized: "JavaScript in the preview is on (click to turn it off). With Network also on, the page can send what it shows elsewhere. Turns off when the file reloads from disk.")
                                      : String(localized: "Allow JavaScript in the preview (off by default). Only for pages you trust: with Network also on, the page's script can send what it shows elsewhere. Files next to it stay limited to images, fonts and CSS."), s.allowJavaScript)
        case .allowNetwork:
            return ("network", String(localized: "Allow Network"),
                    s.allowNetwork ? String(localized: "Network access in the preview is on (click to turn it off). With JavaScript also on, the page can send data anywhere. Turns off when the file reloads from disk.")
                                   : String(localized: "Allow the preview to load from the network (off by default). With JavaScript also on, the page's script can send data anywhere."), s.allowNetwork)
        case .detach:
            return s.detached
                ? ("sidebar.right", String(localized: "Attach"), String(localized: "Dock the preview beside the text again (⇧⌥⌘P)"), false)
                : ("macwindow.badge.plus", String(localized: "Detach"), String(localized: "Move the preview into its own window (⇧⌥⌘P)"), false)
        case .sortReset: return ("arrow.uturn.backward", String(localized: "Unsort"), String(localized: "Back to file order"), false)
        case .export, .rowCount: return ("", "", "", false)
        }
    }

    @objc private func pressed(_ sender: NSButton) {
        guard let item = buttons.first(where: { $0.value === sender })?.key else { return }
        onAction?(item)
    }

    @objc func exportHTML(_ sender: Any?) { onExport?(true) }
    @objc func exportPDF(_ sender: Any?) { onExport?(false) }

    /// Width of the buttons shown (the row count goes left of them).
    var buttonsWidth: CGFloat {
        let n = state.items.filter { $0 != .rowCount }.count
        return n == 0 ? 0 : CGFloat(n) * Self.buttonSize.width + CGFloat(n - 1) * Self.gap
    }

    override func layout() {
        super.layout()
        // Right to left, in reverse item order.
        var x = bounds.width
        let y = (bounds.height - Self.buttonSize.height) / 2
        for item in state.items.reversed() where item != .rowCount {
            guard let v = view(item) else { continue }
            x -= Self.buttonSize.width
            v.frame = NSRect(x: x, y: y, width: Self.buttonSize.width, height: Self.buttonSize.height)
            x -= Self.gap
        }
        layoutRowLabel()
    }

    private func layoutRowLabel() {
        guard !rowLabel.isHidden else { return }
        let size = rowLabelSize
        let right = bounds.width - buttonsWidth - 6
        let w = min(size.width, max(0, right))
        rowLabel.frame = NSRect(x: right - w, y: (bounds.height - size.height) / 2, width: w, height: size.height)
    }

    private var rowLabelSize: NSSize {
        let font = rowLabel.font ?? .systemFont(ofSize: 11)
        let w = (rowLabel.stringValue as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: ceil(w) + 6, height: ceil(font.ascender - font.descender + font.leading) + 2)
    }

    /// What the title may keep: the room left of the bar's buttons and label.
    var usedWidth: CGFloat {
        buttonsWidth + (rowLabel.isHidden ? 0 : rowLabelSize.width + 6)
    }
}

/// The preview with its header (title and the quick-actions bar), docked
/// beside the editor or alone in its own window.
@MainActor
final class PreviewPane: NSView {
    private(set) var renderer: PreviewRenderer
    let header = NSView()
    let titleLabel = NSTextField(labelWithString: String(localized: "Preview"))
    let bar = PreviewBar()
    /// The bar's Detach / Attach button.
    var detachButton: NSButton { bar.buttons[.detach]! }
    static let headerHeight: CGFloat = 24
    private var headerColor = NSColor.windowBackgroundColor

    init(renderer: PreviewRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        header.wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        header.addSubview(titleLabel)
        header.addSubview(bar)
        addSubview(header)
        addSubview(renderer.view)
        setDetached(false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Swaps in another renderer (the language changed to one it doesn't draw).
    func replaceRenderer(_ r: PreviewRenderer) {
        renderer.view.removeFromSuperview()
        renderer = r
        addSubview(r.view)
        needsLayout = true
    }

    func setDetached(_ detached: Bool) {
        var s = bar.state
        s.detached = detached
        if s.items.isEmpty { s.items = [.detach] }
        bar.apply(s)
        needsLayout = true
    }

    func applyPalette(_ p: EditorPalette) {
        headerColor = NSColor(hex: p.statusBar)
        header.layer?.backgroundColor = headerColor.cgColor
        // The symbols and the title follow the theme, not the system.
        header.appearance = NSAppearance(named: p.isDark ? .darkAqua : .aqua)
    }

    override func layout() {
        super.layout()
        let h = Self.headerHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        bar.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - 4), height: h)
        titleLabel.sizeToFit()
        let room = bounds.width - bar.usedWidth - 20
        titleLabel.isHidden = room < 30
        titleLabel.frame = NSRect(x: 8, y: (h - titleLabel.frame.height) / 2, width: max(0, min(titleLabel.frame.width, room)),
                                  height: titleLabel.frame.height)
        renderer.view.frame = NSRect(x: 0, y: h, width: bounds.width, height: max(0, bounds.height - h))
    }
}

/// The detached preview: its own resizable window, "<name> — Preview",
/// bound to its tab's document (it keeps showing that document whichever
/// tab is in front, and closes with it). Closing the window hides the
/// preview; View › Attach Preview docks it again.
@MainActor
final class PreviewWindowController: NSWindowController, NSWindowDelegate {
    private weak var tab: EditorWindowController?
    let pane: PreviewPane
    /// Closed by the app (attach, tab closing), not by the user.
    private var closingQuietly = false

    init(tab: EditorWindowController, pane: PreviewPane, frame: String?) {
        self.tab = tab
        self.pane = pane
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        w.tabbingMode = .disallowed
        w.isRestorable = false
        w.minSize = NSSize(width: 240, height: 160)
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        // The window keeps its own content view for its whole life; the
        // pane (and the preview's WKWebView in it) is a subview, taken out
        // (never swapped out) at the end: replacing a content view with a
        // WKWebView inside traps in WebKit's window-visibility observer
        // (the same fix as MarkdownPDFExport).
        if let content = w.contentView {
            pane.frame = content.bounds
            pane.autoresizingMask = [.width, .height]
            content.addSubview(pane)
        }
        pane.setDetached(true)
        if let frame { w.setFrame(from: frame) } else if let tw = tab.window {
            // Beside the editor window, on the same screen.
            var f = w.frame
            f.size.height = tw.frame.height
            f.origin = NSPoint(x: tw.frame.maxX + 8, y: tw.frame.minY)
            if let s = (tw.screen ?? NSScreen.main)?.visibleFrame, f.maxX > s.maxX { f.origin.x = max(s.minX, s.maxX - f.width) }
            w.setFrame(f, display: false)
        }
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func updateTitle() {
        guard let tab else { return }
        window?.title = String(localized: "\(tab.doc.displayName) — Preview")
        window?.appearance = tab.window?.appearance
    }

    /// Closes the window, keeping the pane (attach) or not (tab closed).
    func closeQuietly() {
        closingQuietly = true
        window?.close()
    }

    /// Attach, or the preview closed from its tab: takes the pane out of
    /// the window (on the main thread; the content view itself is never
    /// swapped), closes the window quietly, and keeps this controller (and
    /// so the window) until the next turn of the run loop, after WebKit is
    /// done with this one.
    func closeReleasingPane() {
        dispatchPrecondition(condition: .onQueue(.main))
        if pane.window === window { pane.removeFromSuperview() }
        closeQuietly()
        DispatchQueue.main.async { withExtendedLifetime(self) {} }
    }

    /// Its tab closed: closes the window and cuts it loose (as the tab's own
    /// views are, EditorWindowController.detachViews): AppKit may keep the
    /// window a while longer, so nothing in it may call back in.
    func closeWithTab() {
        closeReleasingPane()
        tab = nil
        window?.delegate = nil
    }

    func windowWillClose(_ notification: Notification) {
        if !closingQuietly { tab?.previewWindowClosedByUser() }
    }

    func windowDidMove(_ notification: Notification) { tab.map { $0.onChange?($0) } }
    func windowDidResize(_ notification: Notification) { tab.map { $0.onChange?($0) } }
}
