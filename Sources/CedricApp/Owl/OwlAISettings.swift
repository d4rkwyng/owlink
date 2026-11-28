import AppKit
import CedricCore
import CedricAI

/// Where the Cedric AI settings live, plus the run-only overrides the
/// checks use (none of them is saved):
///
///   CEDRIC_AI=1 / 0           enable / disable for this run
///   CEDRIC_AI_BACKEND=builtIn engine (builtIn, lmStudio, ollama, custom, apple)
///   CEDRIC_AI_URL=…           endpoint (Custom)
///   CEDRIC_AI_MODEL=…         model id
///   CEDRIC_AI_PAUSE=5         typing pause before a check, seconds
///   CEDRIC_AI_INTERVAL=90     at most one check per this many seconds
///   CEDRIC_AI_TIMEOUT=20      request cap, seconds
///   CEDRIC_AI_FAKE=1.5        use a fake provider that answers after this many seconds
///   CEDRIC_AI_DEFAULTS=suite  keep the settings in this UserDefaults suite
///   CEDRIC_AI_AUTO=1 / 0      automatic checks on / off (default: on, off on Intel)
@MainActor
enum AIStore {
    static let env = DevEnvironment.values
    static var defaults: UserDefaults { env["CEDRIC_AI_DEFAULTS"].flatMap(UserDefaults.init(suiteName:)) ?? .standard }
    static let serverAutomaticChecksAcknowledgedKey = "CedricServerAutomaticChecksAcknowledged"

    static func load() -> LocalAISettings {
        var s = LocalAISettings.load(from: defaults)
        if let v = env["CEDRIC_AI"] { s.enabled = v == "1" }
        if let v = env["CEDRIC_AI_BACKEND"].flatMap(LocalAISettings.Backend.init(rawValue:)) { s.selectBackend(v) }
        if let v = env["CEDRIC_AI_URL"].flatMap(LocalAISettings.parseEndpoint) { s.backend = .custom; s.baseURL = v }
        if let v = env["CEDRIC_AI_MODEL"], !v.isEmpty { s.model = v }
        if let v = env["CEDRIC_AI_PAUSE"].flatMap(Double.init) { s.pauseDelay = v }
        if let v = env["CEDRIC_AI_INTERVAL"].flatMap(Double.init) { s.minInterval = v }
        if let v = env["CEDRIC_AI_TIMEOUT"].flatMap(Double.init) { s.timeout = v }
        if let v = env["CEDRIC_AI_MIN_IDLE"].flatMap(Double.init) { s.minIdle = v }
        if let v = env["CEDRIC_AI_AUTO"] {
            s.automaticChecks = v == "1"
        } else if LocalAISettings.shouldShowAutomaticServerNotice(backend: s.backend, automaticChecks: s.automaticChecks,
                                                                  acknowledged: defaults.bool(forKey: serverAutomaticChecksAcknowledgedKey)) {
            // Unacknowledged saved automatic-on for a server: leave it off until
            // the first-use notice is confirmed in Settings.
            s.automaticChecks = false
        }
        return s
    }

    static func save(_ s: LocalAISettings) {
        s.save(to: defaults)
        MainActor.assumeIsolated { AskCedricEngine.invalidate() }
    }

    /// The real provider, or the fake one under CEDRIC_AI_FAKE.
    static func makeProvider(_ s: LocalAISettings) async -> (any OwlHintProvider)? {
        if let d = env["CEDRIC_AI_FAKE"].flatMap(Double.init) {
            FakeAIProvider.delay.set(d)
            return FakeAIProvider()
        }
        return await LocalAIOwl.makeProvider(settings: s)
    }
}

/// CEDRIC_AI_FAKE: answers after `delay` seconds with one "fix" for the
/// first `0...items.count` in the context (a Swift off-by-one), its range
/// relative to `context.text` like a real provider's. No network.
struct FakeAIProvider: OwlHintProvider {
    final class Delay: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Double = 1.5
        func set(_ x: Double) { lock.withLock { v = x } }
        var value: Double { lock.withLock { v } }
    }
    static let delay = Delay()
    static let needle = "0...items.count"
    let name = "local:fake-qwen"

    func hints(for context: OwlContext) async -> [OwlHint] {
        try? await Task.sleep(nanoseconds: UInt64(Self.delay.value * 1_000_000_000))
        guard !Task.isCancelled else { return [] }
        let r = (context.text as NSString).range(of: Self.needle)
        guard r.location != NSNotFound else { return [] }
        return [OwlHint(id: "fake-off-by-one", kind: .fix, title: "Off by one: the loop runs past the last item",
                        detail: "0...items.count includes items.count; use 0..<items.count.",
                        range: r, replacement: "0..<items.count", source: name)]
    }
}


/// Settings › Cedric's AI part (was the Cedric AI window, with Save and
/// Cancel, until 0.4.1): every control applies the moment it changes. The
/// address applies on Return or when the field loses focus, and only once
/// it is a local one. An address that isn't local applies nothing, except
/// turning AI off, which always applies. What must not happen on its own
/// stays a button: Test Connection, and the built-in model's Download /
/// Pause / Resume / Cancel / Delete. For Built-in the Model popup is also
/// the download chooser: it lists every catalog model, and picking one that
/// isn't downloaded makes it the download target without changing the model
/// in use.
@MainActor
final class AISettingsSection: NSObject {
    /// Applies saved settings one at a time; a burst of changes applies
    /// only the last (never two engine switches at once).
    static let applier = LatestOnlyRunner<LocalAISettings> { await OwlHub.shared.applyAISettings($0) }

    let view: NSView
    let enabledBox = NSButton(checkboxWithTitle: String(localized: "Ask a local model for hints"), target: nil, action: nil)
    let presetPopup = NSPopUpButton()
    let urlField = NSTextField()
    let testButton = NSButton(title: String(localized: "Test Connection"), target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let modelsLabel = NSTextField(wrappingLabelWithString: "")
    let modelPopup = NSPopUpButton()
    let weakLabel = NSTextField(labelWithString: LocalAISettings.weakModelNote)
    let intervalPopup = NSPopUpButton()
    let automaticBox = NSButton(checkboxWithTitle: String(localized: "Check automatically when I pause typing"), target: nil, action: nil)
    let automaticNote = NSTextField(wrappingLabelWithString: "")
    /// Built-in only: load the model when Owlink starts (off by default).
    let launchBox = NSButton(checkboxWithTitle: String(localized: "Load model at launch"), target: nil, action: nil)
    /// One line; the full note is its tooltip (and the checkbox's).
    let launchNote = NSTextField(labelWithString: LocalAISettings.loadModelAtLaunchShortNote)

    private(set) var settings: LocalAISettings
    private var grid: NSGridView?
    let privacyLabel = NSTextField(wrappingLabelWithString: LocalAISettings.privacyNote)
    /// Built-in only: the shown model's buttons (on the Model row), its
    /// status line and where downloads come from.
    let modelsView = BuiltInModelsView()
    /// The Model popup, plus the built-in buttons beside it.
    private(set) lazy var modelRow = NSStackView(views: [modelPopup, modelsView.controls])
    /// The Model row with the built-in status and source lines under it
    /// (one grid cell, so they sit close to the popup).
    private(set) lazy var modelCell = NSStackView(views: [modelRow, modelsView])
    /// Built-in: the catalog model picked in the Model popup that isn't
    /// downloaded yet. The popup shows it (the buttons act on it) while the
    /// saved model, Automatic or an installed one, stays in effect.
    private(set) var builtInTarget: String?
    /// The engine's caveat ("Slow on Intel Macs…"), hidden when it has none.
    let noteLabel = NSTextField(wrappingLabelWithString: "")
    /// The selected engine (the section only talks to `AIEngine`).
    var engine: any AIEngine {
        settings.backend == .builtIn ? BuiltInDownloads.shared.engine : AIEngines.engine(for: settings)
    }
    /// The menu's intervals, plus the saved one if it isn't a menu value.
    private lazy var intervals: [TimeInterval] = Array(Set(LocalAISettings.intervalChoices + [settings.minInterval])).sorted()
    private(set) var report: ConnectionReport?
    private(set) var testing = false
    /// Rows came or went: the window fits the tab again.
    var onResize: (() -> Void)?
    /// After each change is handed to the engine (the checks wait on it).
    private(set) var applyCount = 0
    /// The width of the grid's label column (the Cedric tab's other grid matches it).
    private(set) var labelColumnWidth: CGFloat = 0

    init(settings: LocalAISettings) {
        self.settings = settings
        view = NSView()
        super.init()
        build()
        load()
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func label(_ s: String, for control: NSView) -> NSTextField {
        let l = label(s)
        control.setAccessibilityLabel(s.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
        return l
    }

    private func build() {
        for (b, a) in [(enabledBox, #selector(changed(_:))), (automaticBox, #selector(changed(_:))), (launchBox, #selector(changed(_:))), (testButton, #selector(test))] {
            b.target = self; b.action = a
        }
        for p in [presetPopup, modelPopup, intervalPopup] { p.target = self; p.action = #selector(changed(_:)) }
        // "Where the AI runs": every engine, unavailable ones disabled.
        presetPopup.autoenablesItems = false
        for kind in LocalAISettings.Backend.allCases {
            var probe = settings
            probe.backend = kind
            let engine = AIEngines.engine(for: probe)
            presetPopup.addItem(withTitle: engine.title)
            presetPopup.lastItem?.isEnabled = engine.isAvailable
            presetPopup.lastItem?.toolTip = engine.unavailableReason
        }
        for v in intervals {
            intervalPopup.addItem(withTitle: v == 1 ? String(localized: "1 second")
                                  : v < 120 ? String(localized: "\(Int(v)) seconds") : String(localized: "\(Int(v) / 60) minutes"))
        }
        urlField.target = self
        urlField.action = #selector(changed(_:))
        urlField.cell?.sendsActionOnEndEditing = true
        urlField.placeholderString = "http://studio.local:1234/v1"
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let privacy = privacyLabel
        privacy.font = small
        privacy.textColor = .secondaryLabelColor
        for l in [statusLabel, modelsLabel, weakLabel, noteLabel, automaticNote, launchNote] { l.font = small }
        automaticNote.textColor = .secondaryLabelColor
        launchNote.textColor = .secondaryLabelColor
        launchNote.lineBreakMode = .byTruncatingTail
        launchNote.toolTip = LocalAISettings.loadModelAtLaunchNote
        launchBox.toolTip = LocalAISettings.loadModelAtLaunchNote
        modelRow.spacing = 8
        modelRow.alignment = .centerY
        modelCell.orientation = .vertical
        modelCell.alignment = .leading
        modelCell.spacing = 2
        noteLabel.textColor = .systemOrange
        modelsView.onChange = { [weak self] in self?.refresh() }
        weakLabel.textColor = .systemOrange
        modelsLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel(String(localized: "Connection status"))

        let testRow = NSStackView(views: [testButton, statusLabel])
        testRow.alignment = .firstBaseline
        let grid = NSGridView(views: [
            [label(String(localized: "AI hints:"), for: enabledBox), enabledBox],
            [label(String(localized: "Where the AI runs:"), for: presetPopup), presetPopup],
            [label(String(localized: "Address:"), for: urlField), urlField],
            [NSGridCell.emptyContentView, privacy],
            [NSGridCell.emptyContentView, noteLabel],
            [NSGridCell.emptyContentView, testRow],
            [NSGridCell.emptyContentView, modelsLabel],
            [label(String(localized: "Model:"), for: modelPopup), modelCell],
            [NSGridCell.emptyContentView, weakLabel],
            [label(String(localized: "Check at most every:"), for: intervalPopup), intervalPopup],
            [NSGridCell.emptyContentView, automaticBox],
            [NSGridCell.emptyContentView, automaticNote],
            [NSGridCell.emptyContentView, launchBox],
            [NSGridCell.emptyContentView, launchNote],
        ])
        // The checkbox says what it does; VoiceOver reads its own title.
        enabledBox.setAccessibilityLabel(nil)
        // The status and source lines under the Model popup (which VoiceOver
        // reads as "Model"); the buttons name the model they act on.
        modelsView.setAccessibilityLabel(String(localized: "Built-in model status"))
        labelColumnWidth = (0..<grid.numberOfRows).compactMap { grid.cell(atColumnIndex: 0, rowIndex: $0).contentView?.fittingSize.width }.max() ?? 0
        grid.column(at: 0).width = labelColumnWidth
        self.grid = grid
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        urlField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        for l in [privacy, modelsLabel, statusLabel, noteLabel, automaticNote, launchNote] as [NSTextField] {
            l.preferredMaxLayoutWidth = 380
            // Without a hard cap a wrapping label in a grid column takes its
            // one-line width and runs into the window's edge.
            l.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.topAnchor.constraint(equalTo: view.topAnchor),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Settings → controls.
    private func load() {
        enabledBox.state = settings.enabled ? .on : .off
        presetPopup.selectItem(at: LocalAISettings.Backend.allCases.firstIndex(of: settings.backend) ?? 0)
        urlField.stringValue = settings.baseURL.absoluteString
        intervalPopup.selectItem(at: intervals.firstIndex(of: settings.minInterval) ?? 0)
        automaticBox.state = settings.automaticChecks ? .on : .off
        launchBox.state = settings.loadModelAtLaunch ? .on : .off
        refresh()
    }

    /// The saved settings may have changed elsewhere (Ask Cedric's setup):
    /// show them, unless a change of ours is still being applied or typed.
    func reloadIfIdle() {
        guard !Self.applier.isBusy, !testing, urlField.currentEditor() == nil else { return }
        let saved = AIStore.load()
        guard saved != settings else { return }
        settings = saved
        report = nil
        load()
    }

    /// The models the popup offers: the tested list (no embedding models),
    /// plus the saved model if the list doesn't have it.
    private var offered: [LocalModelInfo] {
        // Built-in: the downloaded models, known without a test.
        var list = settings.backend == .builtIn ? BuiltInDownloads.shared.engine.installedModels.map(\.info)
            : (report?.models ?? []).filter { !$0.isEmbedding }
        if let m = settings.model, !list.contains(where: { $0.id == m }) { list.insert(LocalModelInfo(id: m), at: 0) }
        return list
    }

    /// The model hints would use: the chosen one, or the suggestion.
    var effectiveModel: LocalModelInfo? {
        if let m = settings.model { return offered.first { $0.id == m } ?? LocalModelInfo(id: m) }
        return suggested
    }

    /// The automatic choice: built-in knows it from the downloads.
    private var suggested: LocalModelInfo? {
        settings.backend == .builtIn ? BuiltInDownloads.shared.engine.suggestedModel(in: offered) : report?.suggested
    }

    private func refresh() {
        // An invalid address rejects the edit: these show the saved settings again.
        enabledBox.state = settings.enabled ? .on : .off
        presetPopup.selectItem(at: LocalAISettings.Backend.allCases.firstIndex(of: settings.backend) ?? 0)
        intervalPopup.selectItem(at: intervals.firstIndex(of: settings.minInterval) ?? 0)
        automaticBox.state = settings.automaticChecks ? .on : .off
        launchBox.state = settings.loadModelAtLaunch ? .on : .off
        let custom = settings.backend == .custom
        let needsAddress = engine.needsAddress
        grid?.cell(for: urlField)?.row?.isHidden = !needsAddress
        privacyLabel.stringValue = needsAddress ? LocalAISettings.privacyNote : LocalAISettings.privacyNoteOnDevice
        urlField.isEditable = custom
        urlField.isSelectable = true
        urlField.textColor = custom ? .labelColor : .secondaryLabelColor
        if !custom { urlField.stringValue = settings.baseURL.absoluteString }

        let builtIn = settings.backend == .builtIn
        let apple = settings.backend == .apple
        modelsView.isHidden = !builtIn
        modelsView.controls.isHidden = !builtIn
        // Only the built-in engine loads a model into Owlink itself.
        grid?.cell(for: launchBox)?.row?.isHidden = !builtIn
        grid?.cell(for: launchNote)?.row?.isHidden = !builtIn
        // Apple Intelligence has one model and no server: no model menu,
        // no Test Connection, just whether it's ready.
        enabledBox.title = apple ? String(localized: "Ask Apple Intelligence for hints") : String(localized: "Ask a local model for hints")
        testButton.isHidden = apple
        if apple {
            let st = AppleFoundationModelsProvider.status
            status(st.message.map { String(localized: "Apple Intelligence: \($0)") } ?? String(localized: "Apple Intelligence: ready"),
                   error: st != .available)
        } else if testButton.isHidden == false, statusLabel.stringValue.hasPrefix("Apple Intelligence:") {
            status("")
        }
        noteLabel.stringValue = engine.note ?? ""
        grid?.cell(for: noteLabel)?.row?.isHidden = engine.note == nil
        let serverDefault = settings.backend.usesServer
        automaticNote.stringValue = serverDefault
            ? String(localized: "Automatic checks are off by default for LM Studio, Ollama and custom servers. Review the first-use notice before enabling them.")
            : String(localized: "Off by default on Intel Macs, so the editor stays fast. Click the owl and choose Ask AI Now to check.")

        if !builtIn { builtInTarget = nil }
        let auto: String
        if builtIn { auto = BuiltInModel.automaticTitle(suggested: suggested?.id) }
        else if let s = suggested { auto = String(localized: "Automatic (\(s.id))") }
        else if report != nil { auto = String(localized: "Automatic (no small Qwen found)") }
        else { auto = String(localized: "Automatic (small Qwen)") }
        if builtIn {
            refreshBuiltInMenu(automatic: auto)
        } else {
            setModelItems([MenuEntry(title: auto, id: nil, toolTip: nil)]
                          + offered.map { MenuEntry(title: $0.sizeLabel.isEmpty ? $0.id : "\($0.id)  (\($0.sizeLabel))", id: $0.id, toolTip: nil) })
            select(settings.model)
        }
        grid?.cell(for: modelCell)?.row?.isHidden = apple
        let weak = !apple && (effectiveModel.map(ModelPicker.isWeak) ?? false)
        weakLabel.isHidden = !weak
        grid?.cell(for: weakLabel)?.row?.isHidden = !weak

        if let r = report {
            let list = r.models.filter { !$0.isEmbedding }.map { m -> String in
                let tag = m.id == r.suggested?.id ? String(localized: "  ← suggested") : ""
                return "• \(m.id)\(m.sizeLabel.isEmpty ? "" : "  \(m.sizeLabel)")\(tag)"
            }
            modelsLabel.stringValue = list.joined(separator: "\n")
            modelsLabel.isHidden = list.isEmpty
        } else {
            modelsLabel.stringValue = ""
            modelsLabel.isHidden = true
        }
        grid?.cell(for: modelsLabel)?.row?.isHidden = modelsLabel.isHidden
        // The interval only matters for automatic checks; explain whichever default applies here.
        intervalPopup.isEnabled = settings.automaticChecks
        grid?.cell(for: automaticNote)?.row?.isHidden = LocalAISettings.defaultAutomaticChecks(for: settings.backend)
        onResize?()
    }

    private struct MenuEntry: Equatable {
        var title: String
        var id: String?
        var toolTip: String?
    }

    /// Replaces the Model popup's items only when they differ: a download's
    /// progress refreshes this many times a second, and rebuilding the menu
    /// each time would disturb it while it is open.
    private func setModelItems(_ entries: [MenuEntry]) {
        let current = modelPopup.itemArray.map { MenuEntry(title: $0.title, id: $0.representedObject as? String, toolTip: $0.toolTip) }
        guard current != entries else { return }
        modelPopup.removeAllItems()
        for e in entries {
            modelPopup.addItem(withTitle: e.title)
            modelPopup.lastItem?.representedObject = e.id
            modelPopup.lastItem?.toolTip = e.toolTip
        }
    }

    private func select(_ id: String?) {
        if let id, let i = modelPopup.itemArray.firstIndex(where: { $0.representedObject as? String == id }) {
            modelPopup.selectItem(at: i)
        } else {
            modelPopup.selectItem(at: 0)
        }
    }

    /// Built-in: after Automatic, every catalog model with its tag
    /// (recommended, non-commercial or size), installed or not. Shows the
    /// download target if there is one, else the model in effect, and points
    /// the buttons and status line at it (for Automatic: the model it uses,
    /// or the default when none is downloaded).
    private func refreshBuiltInMenu(automatic auto: String) {
        let downloads = BuiltInDownloads.shared
        let catalog = downloads.catalog
        // A target that finished downloading stops being one: the popup goes
        // back to the model in effect (a download never switches it).
        if let t = builtInTarget, let m = catalog?.model(id: t), downloads.state(m) == .installed { builtInTarget = nil }
        if let t = builtInTarget, catalog?.model(id: t) == nil { builtInTarget = nil }
        var entries = [MenuEntry(title: auto, id: nil, toolTip: nil)]
        // A saved model the catalog doesn't list (CEDRIC_AI_MODEL, an old id) still shows.
        if let m = settings.model, catalog?.model(id: m) == nil { entries.append(MenuEntry(title: m, id: m, toolTip: nil)) }
        entries += (catalog?.models ?? []).map { MenuEntry(title: $0.menuTitle, id: $0.id, toolTip: $0.details) }
        setModelItems(entries)
        select(builtInTarget ?? settings.model)
        let shownID = modelPopup.selectedItem?.representedObject as? String
        let automatic = shownID == nil
        let shown = automatic ? (catalog?.model(id: suggested?.id) ?? catalog?.defaultModel) : catalog?.model(id: shownID)
        modelPopup.toolTip = shown?.details
        modelsView.show(shown, automatic: automatic)
    }

    private func showAutomaticServerNotice() {
        let host = settings.baseURL.host ?? settings.baseURL.absoluteString
        let server: String
        switch settings.backend {
        case .lmStudio: server = "LM Studio at \(host)"
        case .ollama: server = "Ollama at \(host)"
        case .custom: server = "the server at \(host)"
        case .builtIn, .apple: return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Allow automatic checks to send text to \(server)?")
        alert.informativeText = String(localized: "When you pause typing, Cedric will send the visible text (up to 8 KB) to \(server) for automatic checks and automatic AI grammar. It is not sent to the cloud and stays on your local network.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Confirm"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { self?.refresh(); return }
            AIStore.defaults.set(true, forKey: AIStore.serverAutomaticChecksAcknowledgedKey)
            self.settings.automaticChecks = true
            self.apply()
            self.refresh()
        }
        if let window = view.window { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }

    /// The Model popup's choice; a built-in download target isn't one (the
    /// model in effect stays).
    private var draftModel: String? {
        let picked = modelPopup.selectedItem?.representedObject as? String
        if settings.backend == .builtIn, let t = builtInTarget, picked == t { return settings.model }
        return picked
    }

    /// The controls, for `LocalAISettings.readControls` (address validated first).
    private func draft() -> LocalAISettings.ControlDraft {
        .init(enabled: enabledBox.state == .on,
              backend: LocalAISettings.Backend.allCases[max(0, presetPopup.indexOfSelectedItem)],
              addressText: urlField.stringValue,
              model: draftModel,
              minInterval: intervals[max(0, intervalPopup.indexOfSelectedItem)],
              automaticChecks: automaticBox.state == .on,
              loadModelAtLaunch: launchBox.state == .on)
    }

    private func adopt(_ next: LocalAISettings) {
        if next.backend != settings.backend || next.baseURL != settings.baseURL { report = nil }
        settings = next
    }

    private func rejectAddress() {
        status(String(localized: "Not an address on this Mac or the local network."), error: true)
    }

    private func status(_ s: String, error: Bool = false) {
        statusLabel.stringValue = s
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }

    /// Any control: validate, and if the result is new, apply it. An invalid
    /// address applies only a turn-off; every other control snaps back.
    @objc private func changed(_ sender: Any?) {
        if (sender as? NSPopUpButton) === modelPopup, settings.backend == .builtIn {
            // An installed model (or Automatic) is a choice; one that isn't
            // downloaded is only what the buttons act on.
            let downloads = BuiltInDownloads.shared
            let picked = (modelPopup.selectedItem?.representedObject as? String).flatMap { downloads.catalog?.model(id: $0) }
            builtInTarget = picked.flatMap { downloads.state($0) == .installed ? nil : $0.id }
        }
        let controls = draft()
        if !settings.automaticChecks, controls.backend == settings.backend,
           LocalAISettings.shouldShowAutomaticServerNotice(backend: controls.backend,
                                                           automaticChecks: controls.automaticChecks,
                                                           acknowledged: AIStore.defaults.bool(forKey: AIStore.serverAutomaticChecksAcknowledgedKey)) {
            automaticBox.state = .off
            showAutomaticServerNotice()
            return
        }
        let before = settings
        switch settings.readControls(controls) {
        case .apply(let next):
            adopt(next)
            status("")
            if settings != before { apply() }
        case .disable(let next):
            adopt(next)
            rejectAddress()
            if settings != before { apply() }
        case .invalidAddress:
            rejectAddress()
        }
        refresh()
    }

    /// Saves and hands the settings to the engine (in order, newest wins).
    private func apply() {
        applyCount += 1
        Self.applier.submit(settings)
    }

    @objc func test() {
        guard !testing else { return }
        switch settings.readControls(draft()) {
        case .apply(let next):
            adopt(next)
        case .disable, .invalidAddress:
            rejectAddress()
            refresh()
            return
        }
        testing = true
        testButton.isEnabled = false
        let builtIn = settings.backend == .builtIn
        status(builtIn ? String(localized: "Loading the model…") : String(localized: "Connecting…"))
        var quick = settings
        quick.timeout = 5
        let engine = builtIn ? self.engine : AIEngines.engine(for: quick)
        Task { @MainActor in
            let r = await engine.test()
            testing = false
            testButton.isEnabled = true
            report = r
            if let e = r.error {
                status(builtIn ? String(localized: "Couldn’t run the model (\(Self.describe(e))).")
                               : String(localized: "Couldn’t connect (\(Self.describe(e))). Is the server running?"), error: true)
            } else if builtIn {
                status(String(localized: "Loaded and answered in \(Int(r.latency * 1000)) ms."))
            } else {
                let n = r.models.filter { !$0.isEmbedding }.count
                status(String(localized: "Connected in \(Int(r.latency * 1000)) ms: \(n) models."))
            }
            refresh()
        }
    }

    static func describe(_ e: LocalAIError) -> String {
        switch e {
        case .endpointNotLocal: return String(localized: "not a local address")
        case .http(let c): return "HTTP \(c)"
        case .timedOut: return String(localized: "timed out")
        case .transport(let s): return s
        case .badResponse: return String(localized: "unexpected answer")
        case .cancelled: return String(localized: "cancelled")
        }
    }
}
