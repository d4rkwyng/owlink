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
        for m in catalog?.models ?? [] {
            states[m.id] = store.isInstalled(m) ? .installed
                : store.partialBytes(m) > 0 ? .paused(received: store.partialBytes(m), total: m.sizeBytes) : .notDownloaded
        }
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

/// One row per catalog model: name, size, licence, state, and Download /
/// Pause / Resume / Cancel / Delete.
@MainActor
final class BuiltInModelsView: NSStackView {
    final class Row: NSStackView {
        let model: BuiltInModel
        let title = NSTextField(labelWithString: "")
        let detail = NSTextField(wrappingLabelWithString: "")
        let status = NSTextField(labelWithString: "")
        let progress = NSProgressIndicator()
        let action = NSButton(title: "", target: nil, action: nil)
        let secondary = NSButton(title: "", target: nil, action: nil)

        init(model: BuiltInModel) {
            self.model = model
            super.init(frame: .zero)
            orientation = .vertical
            alignment = .leading
            spacing = 3
            title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            detail.font = small
            detail.textColor = .secondaryLabelColor
            detail.preferredMaxLayoutWidth = 380
            status.font = small
            progress.style = .bar
            progress.isIndeterminate = false
            progress.minValue = 0
            progress.maxValue = 1
            progress.controlSize = .small
            progress.widthAnchor.constraint(equalToConstant: 150).isActive = true
            for b in [action, secondary] { b.controlSize = .small; b.bezelStyle = .rounded }
            title.setContentCompressionResistancePriority(.required, for: .horizontal)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let line = NSStackView(views: [title, spacer, action, secondary])
            line.spacing = 6
            line.alignment = .centerY
            line.widthAnchor.constraint(equalToConstant: 380).isActive = true
            let statusLine = NSStackView(views: [progress, status])
            statusLine.spacing = 8
            statusLine.alignment = .centerY
            addArrangedSubview(line)
            addArrangedSubview(detail)
            addArrangedSubview(statusLine)
        }

        required init?(coder: NSCoder) { fatalError() }

        private func showTitle(_ button: NSButton, _ title: String, _ spoken: String) {
            button.title = title
            button.setAccessibilityLabel(spoken)
        }

        func show(_ state: ModelDownloadState) {
            var name = model.name
            if model.isDefault { name += String(localized: " (recommended)") }
            title.stringValue = name
            var d = "\(model.summary) \(model.shortDescription). \(String(localized: "Licence")): \(model.license)."
            if model.needsMoreMemory() { d += " " + String(localized: "Needs \(model.minRAMGB) GB of memory; this Mac has less.") }
            detail.stringValue = d
            status.textColor = .secondaryLabelColor
            progress.isHidden = true
            secondary.isHidden = true
            action.isEnabled = true
            let f = ByteCountFormatter()
            let modelName = model.name
            switch state {
            case .notDownloaded:
                showTitle(action, String(localized: "Download"), String(localized: "Download \(modelName)"))
                status.stringValue = ""
            case .downloading(let r, let t):
                showTitle(action, String(localized: "Pause"), String(localized: "Pause \(modelName)"))
                showTitle(secondary, String(localized: "Cancel"), String(localized: "Cancel \(modelName)"))
                secondary.isHidden = false
                progress.isHidden = false; progress.doubleValue = state.fraction ?? 0
                status.stringValue = String(localized: "Downloading \(f.string(fromByteCount: r)) of \(f.string(fromByteCount: t))…")
            case .paused(let r, let t):
                showTitle(action, String(localized: "Resume"), String(localized: "Resume \(modelName)"))
                showTitle(secondary, String(localized: "Cancel"), String(localized: "Cancel \(modelName)"))
                secondary.isHidden = false
                progress.isHidden = false; progress.doubleValue = state.fraction ?? 0
                status.stringValue = String(localized: "Paused at \(f.string(fromByteCount: r)) of \(f.string(fromByteCount: t)).")
            case .verifying:
                showTitle(action, String(localized: "Verifying…"), String(localized: "Verifying \(modelName)"))
                action.isEnabled = false
                status.stringValue = String(localized: "Checking the SHA-256…")
            case .installed:
                showTitle(action, String(localized: "Delete"), String(localized: "Delete \(modelName)"))
                status.stringValue = String(localized: "Downloaded and verified.")
                status.textColor = .systemGreen
            case .failed(let e):
                showTitle(action, String(localized: "Download"), String(localized: "Download \(modelName)"))
                status.stringValue = e.message
                status.textColor = .systemRed
            }
            status.isHidden = status.stringValue.isEmpty
            status.superview?.isHidden = status.isHidden && progress.isHidden
        }
    }

    let downloads: BuiltInDownloads
    private(set) var rows: [Row] = []
    private var token: UUID?
    private(set) var licenseConfirmationAlert: NSAlert?
    /// After any state change (the sheet refreshes its model menu).
    var onChange: (() -> Void)?

    init(downloads: BuiltInDownloads = .shared) {
        self.downloads = downloads
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        for m in downloads.catalog?.models ?? [] {
            let row = Row(model: m)
            row.action.target = self; row.action.action = #selector(primary(_:))
            row.secondary.target = self; row.secondary.action = #selector(secondary(_:))
            rows.append(row)
            addArrangedSubview(row)
        }
        let where_ = NSTextField(wrappingLabelWithString: String(localized: "Downloaded from Hugging Face into \((downloads.store.directory.path as NSString).abbreviatingWithTildeInPath). The model runs on this Mac; nothing is sent anywhere."))
        where_.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        where_.textColor = .secondaryLabelColor
        where_.preferredMaxLayoutWidth = 380
        addArrangedSubview(where_)
        token = downloads.observe { [weak self] in self?.reload() }
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    func detach() { if let token { downloads.stopObserving(token) }; token = nil }

    func reload() {
        for r in rows { r.show(downloads.state(r.model)) }
        onChange?()
    }

    func row(_ id: String) -> Row? { rows.first { $0.model.id == id } }

    @objc func primary(_ sender: NSButton) {
        guard let row = rows.first(where: { $0.action === sender }) else { return }
        switch downloads.state(row.model) {
        case .notDownloaded, .failed: confirmDownload(row.model)
        case .paused: downloads.download(row.model)
        case .downloading: downloads.pause(row.model)
        case .installed: downloads.delete(row.model)
        case .verifying: break
        }
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
        guard let row = rows.first(where: { $0.secondary === sender }) else { return }
        downloads.cancel(row.model)
    }
}
