import AppKit
import CedricCore
import CedricAI

/// The app's one model downloader and the latest state of every catalog
/// model, on the main actor for the settings sheet.
@MainActor
final class BuiltInDownloads {
    static let shared = BuiltInDownloads()

    let catalog: ModelCatalog?
    let store: ModelStore
    let downloader: ModelDownloader
    private(set) var states: [String: ModelDownloadState] = [:]
    private var observers: [UUID: () -> Void] = [:]

    private init() {
        catalog = ModelCatalog.bundled()
        store = ModelStore()   // CEDRIC_MODELS_DIR overrides the directory
        downloader = ModelDownloader(store: store)
        for m in catalog?.models ?? [] { states[m.id] = Self.stored(m, in: store) }
        Task {
            await downloader.setObserver { id, state in
                Task { @MainActor in BuiltInDownloads.shared.update(id, state) }
            }
        }
    }

    var engine: BuiltInEngine { BuiltInEngine(catalog: catalog, store: store) }

    func state(_ m: BuiltInModel) -> ModelDownloadState { states[m.id] ?? .notDownloaded }

    @discardableResult
    func observe(_ f: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = f
        return id
    }

    func stopObserving(_ id: UUID) { observers[id] = nil }

    private func update(_ id: String, _ state: ModelDownloadState) {
        states[id] = state
        observers.values.forEach { $0() }
    }

    /// Checks only (CEDRIC_CHECK=settings): a download state as the
    /// downloader would report it (progress, pause), with nothing downloaded.
    func simulateForCheck(_ id: String, _ state: ModelDownloadState) {
        guard DevEnvironment.checksEnabled else { return }
        update(id, state)
    }

    /// Checks only: read every model's state from the models folder again
    /// (after the check put a stand-in model in its own temp folder).
    func rescanForCheck() {
        guard DevEnvironment.checksEnabled else { return }
        for m in catalog?.models ?? [] { states[m.id] = Self.stored(m, in: store) }
        observers.values.forEach { $0() }
    }

    /// What the models folder holds for `m`.
    private static func stored(_ m: BuiltInModel, in store: ModelStore) -> ModelDownloadState {
        if store.isInstalled(m) { return .installed }
        let part = store.partialBytes(m)
        return part > 0 ? .paused(received: part, total: m.sizeBytes) : .notDownloaded
    }

    func download(_ m: BuiltInModel) {
        Task {
            do { try await downloader.start(m) } catch let e as ModelDownloadError { update(m.id, .failed(e)) } catch {}
        }
    }

    func pause(_ m: BuiltInModel) { Task { await downloader.pause(m) } }
    func cancel(_ m: BuiltInModel) { Task { await downloader.cancel(m) } }

    func delete(_ m: BuiltInModel) {
        Task {
            if await BuiltInModelHost.shared.loadedPath == store.fileURL(for: m) { await BuiltInModelHost.shared.unload() }
            do { try await downloader.delete(m) } catch { update(m.id, .failed(.io(error.localizedDescription))) }
        }
    }
}

/// The built-in engine's compact chooser parts. Settings › Cedric's one
/// Model popup picks the model; this shows that model's Download / Pause /
/// Resume / Delete (`action`) and, while it downloads or is paused, Cancel
/// (`secondary`), both on the popup's row (`controls`), plus an info button
/// whose popover has the full description. The view itself is one status
/// line (state, with a small progress bar) and one line saying where models
/// come from (the full text in its tooltip).
@MainActor
final class BuiltInModelsView: NSStackView {
    let downloads: BuiltInDownloads
    /// The model the buttons and status act on: the popup's download target,
    /// or with Automatic selected, the one Automatic uses (or would).
    private(set) var model: BuiltInModel?
    /// Automatic is selected: the status line names the model it uses.
    private(set) var automatic = false
    let action = NSButton(title: "", target: nil, action: nil)
    let secondary = NSButton(title: "", target: nil, action: nil)
    let info = NSButton(title: "", target: nil, action: nil)
    /// action, secondary and info: next to the Model popup.
    let controls: NSStackView
    let status = NSTextField(labelWithString: "")
    let progress = NSProgressIndicator()
    let source = NSTextField(labelWithString: "")
    private var token: UUID?
    private(set) var licenseConfirmationAlert: NSAlert?
    private(set) var infoPopover: NSPopover?
    /// After any download state change (the section refreshes its Model menu).
    var onChange: (() -> Void)?

    init(downloads: BuiltInDownloads = .shared) {
        self.downloads = downloads
        controls = NSStackView(views: [action, secondary, info])
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        controls.spacing = 4
        controls.alignment = .centerY
        for b in [action, secondary] { b.controlSize = .small; b.bezelStyle = .rounded }
        action.target = self; action.action = #selector(primary(_:))
        secondary.target = self; secondary.action = #selector(secondary(_:))
        info.bezelStyle = .inline
        info.isBordered = false
        info.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: String(localized: "Model details"))
        info.imagePosition = .imageOnly
        info.target = self; info.action = #selector(showInfo(_:))
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        status.font = small
        status.lineBreakMode = .byTruncatingTail
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let statusLine = NSStackView(views: [progress, status])
        statusLine.spacing = 6
        statusLine.alignment = .centerY
        let folder = (downloads.store.directory.path as NSString).abbreviatingWithTildeInPath
        source.stringValue = String(localized: "Downloaded from Hugging Face into \(folder).")
        source.toolTip = String(localized: "Downloaded from Hugging Face into \(folder). The model runs on this Mac; nothing is sent anywhere.")
        source.font = small
        source.textColor = .secondaryLabelColor
        source.lineBreakMode = .byTruncatingMiddle
        for l in [status, source] {
            l.maximumNumberOfLines = 1
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            l.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        }
        addArrangedSubview(statusLine)
        addArrangedSubview(source)
        token = downloads.observe { [weak self] in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func detach() { if let token { downloads.stopObserving(token) }; token = nil }

    /// A download state changed: show it, and let the section refresh.
    func reload() {
        update()
        onChange?()
    }

    /// The model ID the popup shows that the catalog doesn't list (an old
    /// saved one, CEDRIC_AI_MODEL), when `model` is nil because of it.
    private(set) var unavailableID: String?

    /// The popup now shows `model` (Automatic: the one it uses or would),
    /// or `unavailableID`, a saved model this build doesn't have.
    func show(_ model: BuiltInModel?, automatic: Bool, unavailableID: String? = nil) {
        self.model = model
        self.automatic = automatic
        self.unavailableID = model == nil ? unavailableID : nil
        update()
    }

    private func showTitle(_ button: NSButton, _ title: String, _ spoken: String) {
        button.title = title
        button.setAccessibilityLabel(spoken)
    }

    private func update() {
        status.textColor = .secondaryLabelColor
        progress.isHidden = true
        secondary.isHidden = true
        action.isEnabled = true
        guard let model else {
            action.isHidden = true
            info.isHidden = true
            let line = unavailableID.map { String(localized: "\($0) isn’t in this build’s model list. Choose a model or Automatic.") }
                ?? String(localized: "No models are bundled with this build.")
            if unavailableID != nil { status.textColor = .systemOrange }
            status.stringValue = line
            status.toolTip = line
            return
        }
        action.isHidden = false
        info.isHidden = false
        let modelName = model.name
        info.setAccessibilityLabel(String(localized: "About \(modelName)"))
        info.toolTip = model.details
        let state = downloads.state(model)
        let f = ByteCountFormatter()
        var line: String
        switch state {
        case .notDownloaded:
            showTitle(action, String(localized: "Download"), String(localized: "Download \(modelName)"))
            line = String(localized: "Not downloaded (\(model.sizeLabel)).")
        case .downloading(let r, let t):
            showTitle(action, String(localized: "Pause"), String(localized: "Pause \(modelName)"))
            showTitle(secondary, String(localized: "Cancel"), String(localized: "Cancel \(modelName)"))
            secondary.isHidden = false
            progress.isHidden = false; progress.doubleValue = state.fraction ?? 0
            line = String(localized: "Downloading \(f.string(fromByteCount: r)) of \(f.string(fromByteCount: t))…")
        case .paused(let r, let t):
            showTitle(action, String(localized: "Resume"), String(localized: "Resume \(modelName)"))
            showTitle(secondary, String(localized: "Cancel"), String(localized: "Cancel \(modelName)"))
            secondary.isHidden = false
            progress.isHidden = false; progress.doubleValue = state.fraction ?? 0
            line = String(localized: "Paused at \(f.string(fromByteCount: r)) of \(f.string(fromByteCount: t)).")
        case .verifying:
            showTitle(action, String(localized: "Verifying…"), String(localized: "Verifying \(modelName)"))
            action.isEnabled = false
            line = String(localized: "Checking the SHA-256…")
        case .installed:
            showTitle(action, String(localized: "Delete"), String(localized: "Delete \(modelName)"))
            line = String(localized: "Downloaded and verified.")
            status.textColor = .systemGreen
        case .failed(let e):
            showTitle(action, String(localized: "Download"), String(localized: "Download \(modelName)"))
            line = e.message
            status.textColor = .systemRed
        }
        if model.needsMoreMemory(), state != .installed {
            line += " " + String(localized: "Needs \(model.minRAMGB) GB of memory; this Mac has less.")
        }
        if automatic { line = String(localized: "Uses \(modelName). ") + line }
        status.stringValue = line
        status.toolTip = line
    }

    @objc func primary(_ sender: NSButton) {
        guard let model else { return }
        switch downloads.state(model) {
        case .notDownloaded, .failed: confirmDownload(model)
        case .paused: downloads.download(model)
        case .downloading: downloads.pause(model)
        case .installed: downloads.delete(model)
        case .verifying: break
        }
    }

    @objc func showInfo(_ sender: NSButton) {
        guard let model else { return }
        infoPopover?.close()
        var text = model.details
        if model.needsMoreMemory() { text += "\n" + String(localized: "This Mac has less memory than that.") }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.isSelectable = true
        label.preferredMaxLayoutWidth = 340
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
        ])
        let vc = NSViewController()
        vc.view = content
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = vc
        infoPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private func confirmDownload(_ model: BuiltInModel) {
        guard let confirmation = model.licenseConfirmation() else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Couldn’t load the model licence")
            alert.informativeText = String(localized: "The bundled licence text is missing. No download was started.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "OK"))
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        text.string = confirmation.body
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isVerticallyResizable = true
        text.textContainer?.containerSize = NSSize(width: 520, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.sizeToFit()
        text.frame.size.width = 520
        let scroll = NSScrollView(frame: text.frame)
        scroll.frame.size.height = 280
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let alert = NSAlert()
        alert.messageText = confirmation.title
        let warning = confirmation.isNonCommercial ? String(localized: "NON-COMMERCIAL licence. ") : ""
        alert.informativeText = warning + String(localized: "Licence: \(confirmation.licenseName). Review the full licence below before downloading.")
        alert.accessoryView = scroll
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Confirm"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        licenseConfirmationAlert = alert
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.licenseConfirmationAlert = nil
            guard response == .alertFirstButtonReturn else { return }
            switch self?.downloads.state(model) {
            case .notDownloaded, .failed: self?.downloads.download(model)
            default: break
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    @objc func secondary(_ sender: NSButton) {
        guard let model else { return }
        downloads.cancel(model)
    }
}
