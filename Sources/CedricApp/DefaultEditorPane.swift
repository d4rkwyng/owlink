import AppKit
import CedricCore
import UniformTypeIdentifiers

/// Launch Services through NSWorkspace (macOS 12+). The deprecated
/// LSSetDefaultRoleHandlerForContentType isn't used: NSWorkspace's call is
/// its replacement and asks the user for consent itself when macOS wants it.
struct WorkspaceDefaultApps: DefaultAppService {
    func defaultApp(forContentType id: String) -> URL? {
        guard let t = UTType(id) else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: t)
    }

    func setDefaultApp(_ app: URL, forContentType id: String) async throws {
        guard let t = UTType(id) else { throw CocoaError(.featureUnsupported) }
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: t)
    }
}

/// Settings › Default editor for…: a box per file type (on = Owlink opens
/// it now) with the app that opens it, and "Use Owlink for All Text Files".
/// Only a click changes anything; opening Settings only reads.
@MainActor
final class DefaultEditorPane: NSObject {
    /// The checks swap in a fake, so they never touch the Mac's real defaults.
    static var makeService: () -> DefaultAppService = { WorkspaceDefaultApps() }

    let model: DefaultEditorModel
    let view = NSStackView()
    private(set) var boxes: [String: NSButton] = [:]
    private(set) var currentLabels: [String: NSTextField] = [:]
    let allButton = NSButton(title: String(localized: "Use Owlink for All Text Files"), target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    private var busy = false

    init(app: URL = Bundle.main.bundleURL) {
        model = DefaultEditorModel(app: app, service: Self.makeService())
        super.init()
        build()
        refresh()
    }

    private func build() {
        let title = NSTextField(labelWithString: String(localized: "Default editor for…"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        var rows: [[NSView]] = []
        for t in DocumentTypes.settingsTypes {
            let box = NSButton(checkboxWithTitle: String(localized: "\(t.name) (.\(t.sampleExtension))"), target: self, action: #selector(toggled(_:)))
            box.identifier = NSUserInterfaceItemIdentifier("defaultEditor.\(t.label)")
            let cur = NSTextField(labelWithString: "")
            cur.textColor = .secondaryLabelColor
            cur.lineBreakMode = .byTruncatingTail
            boxes[t.label] = box
            currentLabels[t.label] = cur
            rows.append([box, cur])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 4
        grid.columnSpacing = 12
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(grid)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        scroll.documentView = doc
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 8),
            grid.topAnchor.constraint(equalTo: doc.topAnchor, constant: 6),
            grid.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -6),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: doc.trailingAnchor, constant: -8),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 196),
            scroll.widthAnchor.constraint(equalToConstant: 400),
        ])
        allButton.target = self
        allButton.action = #selector(useForAll(_:))
        let note = NSTextField(wrappingLabelWithString: String(localized: "Ticked: Owlink opens these files when you double-click them, and Finder shows them with Owlink's document icons. macOS may ask you to confirm each change. Unticking gives the type back to the app that had it before. HTML isn't listed: macOS treats the app for HTML files as your web browser."))
        for l in [note, status] {
            l.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            l.textColor = .secondaryLabelColor
            l.preferredMaxLayoutWidth = 400
        }
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 6
        for v in [title, scroll, allButton, note, status] as [NSView] { view.addArrangedSubview(v) }
    }

    /// Reads the current defaults again (Settings opening, the app becoming active).
    func refresh() {
        model.reload()
        for row in model.rows {
            boxes[row.type.label]?.state = row.isOwlink ? .on : .off
            boxes[row.type.label]?.isEnabled = !busy
            currentLabels[row.type.label]?.stringValue = row.isOwlink ? "Owlink" : row.currentName
        }
        allButton.isEnabled = !busy
    }

    @objc func toggled(_ sender: NSButton) {
        guard let label = boxes.first(where: { $0.value === sender })?.key,
              let type = DocumentTypes.settingsTypes.first(where: { $0.label == label }) else { return }
        let on = sender.state == .on
        run { [model] in
            switch await model.setOwlink(on, for: type) {
            case .done: return on ? String(localized: "Owlink now opens \(type.name) files.") : String(localized: "\(type.name) files open in their earlier app again.")
            case .noPreviousApp: return String(localized: "Owlink doesn't know which app opened \(type.name) files before. Choose one in Finder: Get Info › Open with › Change All.")
            case .failed(let why): return String(localized: "macOS didn't change it: \(why)")
            }
        }
    }

    @objc func useForAll(_ sender: Any?) {
        run { [model] in
            let (n, outcome) = await model.useOwlinkForAll()
            if case .failed(let why) = outcome { return String(localized: "Changed \(n); then macOS didn't: \(why)") }
            return String(localized: "Owlink now opens all \(n) text file types.")
        }
    }

    private func run(_ work: @escaping @MainActor () async -> String) {
        busy = true
        refresh()
        Task { @MainActor in
            let msg = await work()
            busy = false
            status.stringValue = msg
            refresh()
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
