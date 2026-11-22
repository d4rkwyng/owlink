import SwiftUI
import CedricCore
import CedricAI

/// What the AI engines can do here, for Settings and messages.
enum AIStatus {
    static let noEngineMessage = String(localized: "No AI engine is ready. Turn on Apple Intelligence, download a built-in model (on a device) or set up a server on your network in Settings › Cedric AI.")

    static var device: ModelCatalog.Device {
        UIDevice.current.userInterfaceIdiom == .pad
            ? .iPad(physicalMemory: ProcessInfo.processInfo.physicalMemory) : .iPhone
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// The Apple Intelligence row: "Available", or why not.
    static var appleLine: String {
        let s = AppleFoundationModelsProvider.status
        if s == .available { return String(localized: "Available, on this device") }
        return s.message ?? String(localized: "Not available")
    }

    static func describe(_ e: Error) -> String {
        switch e {
        case LocalAIError.timedOut: return String(localized: "The model took too long to answer.")
        case LocalAIError.endpointNotLocal: return String(localized: "The AI address isn’t on the local network.")
        case LocalAIError.http(let c): return String(localized: "The AI server answered with an error (\(c)).")
        case BuiltInError.promptTooLong: return String(localized: "Too much text for this model: select less and ask again.")
        case BuiltInError.notInstalled: return String(localized: "No model downloaded yet: download one in Settings › Cedric AI.")
        case BuiltInError.loadFailed(let why): return why
        default: return String(localized: "Something went wrong: \(String(String(describing: e).prefix(160)))")
        }
    }

    static func backendTitle(_ b: LocalAISettings.Backend) -> String {
        switch b {
        case .apple: return "Apple Intelligence"
        case .builtIn: return String(localized: "Built-in Model")
        case .custom, .lmStudio, .ollama: return String(localized: "Server on Network")
        }
    }
}

/// Settings: the editor (font size, theme, wrap, Cedric's hints) and
/// Cedric AI (off by default; Apple Intelligence's availability; the
/// built-in models on a device; a LAN server).
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettings.Key.fontSize) private var fontSize = AppSettings.defaultFontSize
    @AppStorage(AppSettings.Key.wrap) private var wrap = true
    @AppStorage(AppSettings.Key.lineNumbers) private var lineNumbers = true
    @AppStorage(AppSettings.Key.owlHints) private var owlHints = true
    @AppStorage(AppSettings.Key.theme) private var theme = EditorTheme.system.rawValue
    @AppStorage(AppSettings.Key.saveAutomatically) private var saveAutomatically = true
    @AppStorage(AppSettings.Key.openReadOnly) private var openReadOnly = AppSettings.openReadOnlyDefault
    @AppStorage(AppSettings.Key.styleCheck) private var styleCheck = false
    @AppStorage(AppSettings.Key.readableWidthDefault) private var readableWidthDefault = false
    @State private var styleExtra = ""
    @State private var styleExcept = ""
    @State private var readableColumns = AppSettings.readableColumns
    @State private var ai = AIStore.load()
    @State private var showAutomaticServerNotice = false
    @State private var address = ""
    @State private var testResult: String?
    @StateObject private var models = ModelsModel()

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Editor")) {
                    Stepper(value: $fontSize, in: AppSettings.fontSizes, step: 1) {
                        HStack {
                            Text(String(localized: "Font Size"))
                            Spacer()
                            Text("\(Int(fontSize)) pt").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .accessibilityIdentifier("settings.fontSize")
                    Picker(String(localized: "Theme"), selection: $theme) {
                        ForEach(EditorTheme.allCases, id: \.rawValue) { t in Text(t.displayName).tag(t.rawValue) }
                    }
                    .accessibilityIdentifier("settings.theme")
                    Toggle(String(localized: "Wrap Lines"), isOn: $wrap)
                    Toggle(String(localized: "Show Line Numbers"), isOn: $lineNumbers)
                        .accessibilityIdentifier("settings.lineNumbers")
                    Toggle(String(localized: "Cedric’s Hints"), isOn: $owlHints)
                }
                .onChange(of: fontSize) { AppSettings.post() }
                .onChange(of: wrap) { AppSettings.post() }
                .onChange(of: lineNumbers) { AppSettings.post() }
                .onChange(of: owlHints) { AppSettings.post() }
                .onChange(of: theme) { AppSettings.post() }

                Section {
                    Toggle(String(localized: "Save Automatically"), isOn: $saveAutomatically)
                        .accessibilityIdentifier("settings.saveAutomatically")
                    Toggle(String(localized: "Open Files Read-Only"), isOn: $openReadOnly)
                        .accessibilityIdentifier("settings.openReadOnly")
                } header: {
                    Text(String(localized: "Saving"))
                } footer: {
                    Text(String(localized: "Save Automatically on: changes are saved to the file as you work. Off: the file changes only when you tap Save, and closing asks first. Either way, until changes are saved, Owlink keeps a copy of the unsaved text on this device (not in backups) to offer after a crash, and deletes it when you save or close.\n\nOpen Files Read-Only: files open for reading, and you tap Edit to change them (Done goes back). Files that look binary always open read-only.\n\nOwlink keeps previous versions on this device for up to 7 days: up to 10 recent copies and the version before Owlink first saved after opening or reloading. Automatic saves are copied at most once a minute, and older copies may be removed to limit storage. Restore Previous Version in the document’s menu."))
                }
                .onChange(of: saveAutomatically) { AppSettings.post() }
                .onChange(of: openReadOnly) { AppSettings.post() }

                Section {
                    Toggle(String(localized: "Style Check"), isOn: $styleCheck)
                        .accessibilityIdentifier("settings.styleCheck")
                    TextField(String(localized: "Also flag"), text: $styleExtra)
                        .disabled(!styleCheck)
                        .accessibilityIdentifier("settings.styleExtra")
                    TextField(String(localized: "Never flag"), text: $styleExcept)
                        .disabled(!styleCheck)
                        .accessibilityIdentifier("settings.styleExceptions")
                    Toggle(String(localized: "Readable Width"), isOn: $readableWidthDefault)
                        .accessibilityIdentifier("settings.readableWidth")
                    Stepper(value: $readableColumns, in: ReadableWidth.columnRange) {
                        HStack {
                            Text(String(localized: "Column Width"))
                            Spacer()
                            Text("\(readableColumns)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .accessibilityIdentifier("settings.readableColumns")
                } header: {
                    Text(String(localized: "Writing"))
                } footer: {
                    Text(String(localized: "Style Check points out filler words, redundancies (“past history”) and clichés in Markdown and plain text, one at a time, never in code. Offline, no AI. Off until you turn it on. Separate phrases with commas. Ignore on a hint adds that phrase to Never flag.\n\nReadable Width centres the text in a column while lines wrap. Off until you turn it on. The document menu switches the open file and keeps that choice; this switch is the default for every other file."))
                }
                .onChange(of: styleCheck) { AppSettings.post() }
                .onChange(of: styleExtra) { writeStylePhrases() }
                .onChange(of: styleExcept) { writeStylePhrases() }
                .onChange(of: readableWidthDefault) { AppSettings.post() }
                .onChange(of: readableColumns) { AppSettings.readableColumns = readableColumns }

                Section {
                    LabeledContent(String(localized: "Apple Intelligence"), value: AIStatus.appleLine)
                        .accessibilityIdentifier("settings.appleStatus")
                    Picker(String(localized: "Engine"), selection: Binding(get: { ai.backend.usesServer ? .custom : ai.backend },
                                                                           set: { ai.selectBackend($0); save() })) {
                        ForEach([LocalAISettings.Backend.apple, .builtIn, .custom], id: \.self) { b in
                            Text(AIStatus.backendTitle(b)).tag(b)
                        }
                    }
                    Toggle(String(localized: "Use Cedric AI"), isOn: Binding(get: { ai.enabled }, set: { ai.enabled = $0; save() }))
                        .accessibilityIdentifier("settings.aiEnabled")
                    Toggle(String(localized: "Check automatically when I pause typing"),
                           isOn: Binding(get: { ai.automaticChecks }, set: setAutomaticChecks))
                        .disabled(!ai.enabled)
                        .accessibilityIdentifier("settings.automaticChecks")
                } header: {
                    Text(String(localized: "Cedric AI"))
                } footer: {
                    Text(String(localized: "Off by default. Cedric’s offline hints never need it. Ask Cedric uses Apple Intelligence or the built-in model on this device, or a server on your network if you set one up. Never the cloud."))
                    if ai.backend.usesServer {
                        Text(String(localized: "Automatic checks are off by default for servers on your network. Review the notice before turning them on."))
                    }
                }

                if ai.backend.usesServer {
                    Section {
                        TextField("http://192.168.1.20:1234/v1", text: $address)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onSubmit(applyAddress)
                        Button(String(localized: "Test Connection")) { applyAddress(); test() }
                        if let testResult { Text(testResult).font(.footnote).foregroundStyle(.secondary) }
                    } header: {
                        Text(String(localized: "Server on Your Network"))
                    } footer: {
                        Text(LocalAISettings.privacyNote)
                    }
                }

                if ai.backend == .builtIn { builtInSection }

                Section(String(localized: "About")) {
                    LabeledContent(String(localized: "Version"), value: Self.version)
                    Text(String(localized: "Owlink doesn’t collect anything and uses the network only when you ask: downloading a model, or a server on your network you set up."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(String(localized: "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Done")) { dismiss() } } }
            .alert(String(localized: "Allow automatic checks to send text to \(automaticServerName)?"),
                   isPresented: $showAutomaticServerNotice) {
                Button(String(localized: "Confirm")) {
                    UserDefaults.standard.set(true, forKey: LocalAISettings.serverAutomaticChecksAcknowledgedKey)
                    ai.automaticChecks = true
                    save()
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "When you pause typing, Cedric will send the visible text (up to 8 KB) to \(automaticServerName) for automatic checks. It is not sent to the cloud and stays on your local network."))
            }
            .onAppear {
                address = ai.backend.usesServer ? ai.baseURL.absoluteString : ""
                if styleExtra.isEmpty { styleExtra = AppSettings.styleCheckExtra.joined(separator: ", ") }
                if styleExcept.isEmpty { styleExcept = AppSettings.styleCheckExceptions.joined(separator: ", ") }
            }
            .onReceive(NotificationCenter.default.publisher(for: AppSettings.changed)) { _ in
                // "Ignore this word" appends an exception while this screen is closed
                // or open. Don't overwrite a phrase still being typed.
                let stored = AppSettings.styleCheckExceptions
                if AppSettings.phrases(styleExcept) != stored { styleExcept = stored.joined(separator: ", ") }
            }
        }
    }

    @ViewBuilder private var builtInSection: some View {
        Section {
            if let reason = BuiltInEngine().unavailableReason {
                Text(reason).foregroundStyle(.secondary).accessibilityIdentifier("settings.builtInStatus")
            }
            ForEach(models.offered) { m in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(m.name)
                            Text(m.shortDescription + " · " + m.license).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        modelButton(m)
                    }
                    if let f = models.states[m.id]?.fraction { ProgressView(value: f) }
                    if case .failed(let e) = models.states[m.id] { Text(e.message).font(.caption).foregroundStyle(.red) }
                }
            }
        } header: {
            Text(String(localized: "Built-in Models"))
        } footer: {
            Text(String(localized: "Downloaded from Hugging Face only when you tap Download, checked against its SHA-256, and kept out of iCloud backups. Runs on this device only."))
        }
        .alert(item: $models.confirm) { m in
            Alert(title: Text(String(localized: "Download \(m.name)?")),
                  message: Text(String(localized: "\(m.shortDescription). Licence: \(m.license) (\(m.licenseURL.absoluteString)). It downloads from huggingface.co.")),
                  primaryButton: .default(Text(String(localized: "Download"))) { models.start(m) },
                  secondaryButton: .cancel())
        }
    }

    @ViewBuilder private func modelButton(_ m: BuiltInModel) -> some View {
        switch models.states[m.id] ?? .notDownloaded {
        case .installed:
            Menu(String(localized: "Installed")) {
                Button(String(localized: "Use This Model")) { ai.model = m.id; ai.selectBackend(.builtIn); save() }
                Button(String(localized: "Delete"), role: .destructive) { models.delete(m) }
            }
        case .downloading:
            Button(String(localized: "Pause")) { models.pause(m) }
        case .verifying:
            ProgressView()
        default:
            Button(String(localized: "Download")) { models.confirm = m }.disabled(BuiltInPlatform.runtime == nil)
        }
    }

    /// Writes the comma-separated fields when they differ from what is stored.
    private func writeStylePhrases() {
        let extra = AppSettings.phrases(styleExtra)
        if extra != AppSettings.styleCheckExtra { AppSettings.styleCheckExtra = extra }
        let except = AppSettings.phrases(styleExcept)
        if except != AppSettings.styleCheckExceptions { AppSettings.styleCheckExceptions = except }
    }

    private func save() {
        ai.save()
        AppSettings.post()
    }

    private var automaticServerName: String {
        let host = ai.baseURL.host ?? ai.baseURL.absoluteString
        switch ai.backend {
        case .lmStudio: return String(localized: "LM Studio at \(host)")
        case .ollama: return String(localized: "Ollama at \(host)")
        case .custom: return String(localized: "the server at \(host)")
        case .builtIn, .apple: return ""
        }
    }

    private func setAutomaticChecks(_ enabled: Bool) {
        if LocalAISettings.shouldShowAutomaticServerNotice(
            backend: ai.backend, automaticChecks: enabled,
            acknowledged: UserDefaults.standard.bool(forKey: LocalAISettings.serverAutomaticChecksAcknowledgedKey)) {
            showAutomaticServerNotice = true
            return
        }
        ai.automaticChecks = enabled
        save()
    }

    private func applyAddress() {
        guard let url = LocalAISettings.parseEndpoint(address) else {
            testResult = String(localized: "That isn’t an address Owlink can use.")
            return
        }
        guard LocalEndpointPolicy.isAllowed(url) else {
            testResult = String(localized: "Only addresses on your local network are allowed.")
            return
        }
        ai.baseURL = url
        ai.selectBackend(.custom)
        ai.baseURL = url
        save()
    }

    private func test() {
        testResult = String(localized: "Testing…")
        let engine = AIEngines.engine(for: ai)
        Task {
            let r = await engine.test()
            if let e = r.error {
                testResult = AIStatus.describe(e)
            } else {
                testResult = String(localized: "Connected: \(r.models.count) models, \(Int(r.latency * 1000)) ms.")
                    + (r.suggested.map { " " + String(localized: "Suggested: \($0.id).") } ?? "")
            }
        }
    }

    /// "Owlink 0.3.0": the marketing version only. The build number is
    /// for App Store Connect, not for people (TestFlight still shows it).
    static var version: String { "Owlink \(CedricVersion.string)" }
}

extension BuiltInModel: @retroactive Hashable {
    public func hash(into h: inout Hasher) { h.combine(id) }
}

/// The built-in models offered on this device and their download states.
@MainActor
final class ModelsModel: ObservableObject {
    @Published var states: [String: ModelDownloadState] = [:]
    @Published var confirm: BuiltInModel?
    let offered: [BuiltInModel]
    private let downloader = ModelDownloader()

    init() {
        offered = ModelCatalog.bundled()?.offered(on: AIStatus.device) ?? []
        Task {
            await downloader.setObserver { [weak self] id, state in
                Task { @MainActor in self?.states[id] = state }
            }
            for m in offered { let s = await downloader.state(of: m); states[m.id] = s }
        }
    }

    func start(_ m: BuiltInModel) {
        Task {
            do { try await downloader.start(m) } catch let e as ModelDownloadError { states[m.id] = .failed(e) } catch {}
        }
    }

    func pause(_ m: BuiltInModel) { Task { await downloader.pause(m) } }

    func delete(_ m: BuiltInModel) {
        Task {
            try? await downloader.delete(m)
            states[m.id] = .notDownloaded
        }
    }
}
