import SwiftUI
import CedricCore
import CedricAI

/// Ask Cedric: a question about the document (or a quick action), answered
/// by the engine Settings picked: Apple Intelligence on the device, the
/// built-in model (a device only), or a server on the local network the
/// user set up. Nothing is sent anywhere unless a LAN server is chosen. The
/// core's `OwlChatRunner` runs it, as on the Mac.
@MainActor
final class AskCedricModel: ObservableObject {
    /// One propose_edit (or a quick action's block) shown as a card.
    struct Card: Identifiable, Equatable {
        let id: Int
        var proposal: OwlEditProposal
        var state: OwlEditProposal.ApplyState = .stale
        var shownAll = false
        var needsShowAll: Bool
        var firstLine: Int
        var lastLine: Int
    }

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var role: OwlChatEntry.Role
        var text: String
        var cards: [Card] = []
    }

    /// The live document, for Apply / Skip. Tools still read the snapshot
    /// taken when the question was asked.
    struct DocumentNow {
        var text: NSString
        var generation: Int
        var readOnly: Bool
        var large: Bool
        var lines: LineIndex
    }

    @Published var question = ""
    @Published var entries: [Entry] = []
    @Published var running = false
    @Published var engineTitle: String?
    @Published var unavailable: String?

    let fileName: String?
    let language: Language
    /// What Apply did. `.refused` is a text view that could not place the
    /// range; that is not the document having changed.
    enum ApplyResult { case applied, stale, refused }
    var apply: (OwlEditProposal) -> ApplyResult = { _ in .refused }
    var openSettings: () -> Void = {}
    var documentNow: () -> DocumentNow = { DocumentNow(text: "", generation: 0, readOnly: true, large: false, lines: LineIndex()) }
    var makeSnapshot: () -> OwlDocumentSnapshot = { OwlDocumentSnapshot(text: "", generation: 0) }
    var askIsVisible: () -> Bool = { false }
    private var task: Task<Void, Never>?
    private var recheck: Task<Void, Never>?
    private var lastQuestion = ""
    private var lastAction: OwlQuickAction?
    private let gate = OwlToolGate.bundled()

    init(fileName: String?, language: Language) {
        self.fileName = fileName
        self.language = language
    }

    var prose: Bool { SpellScope.isProse(language) }

    var actions: [OwlQuickAction] {
        OwlQuickAction.allCases.filter { $0 != .scriptSafety && $0.isOffered(prose: prose, language: language) }
    }

    /// The settings Ask Cedric runs on (nil: nothing ready), as on the Mac.
    static func chatSettings() -> LocalAISettings? {
        OwlChatSetup.chatSettings(AIStore.load(), appleAvailable: AppleFoundationModelsProvider.isAvailable,
                                  builtInInstalled: !BuiltInEngine().installedModels.isEmpty)
    }

    func prepare() async {
        guard let s = Self.chatSettings(), let engine = await OwlChatEngines.make(settings: s) else {
            unavailable = AIStatus.noEngineMessage
            return
        }
        engineTitle = engine.title
    }

    func ask(_ q: String, action: OwlQuickAction? = nil) {
        guard !running else { return }
        let shown = action?.title(prose: prose) ?? q
        guard !shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let history = entries.filter { $0.role == .user || $0.role == .owl }.map { OwlChatEntry(role: $0.role, text: $0.text) }
        entries.append(Entry(role: .user, text: shown))
        entries.append(Entry(role: .owl, text: ""))
        question = ""
        running = true
        lastQuestion = q
        lastAction = action
        let snap = makeSnapshot()
        let prose = self.prose
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.running = false }
            guard let s = Self.chatSettings(), let engine = await OwlChatEngines.make(settings: s) else {
                self.finish(error: AIStatus.noEngineMessage)
                return
            }
            self.engineTitle = engine.title
            let scope: OwlChatScope = snap.selection.length > 0 ? .selection : .wholeDocument
            guard let ctx = OwlChatContext.build(snap, scope: scope, budget: engine.contextBudget)
                    ?? OwlChatContext.build(snap, scope: .visible, budget: engine.contextBudget) else {
                self.finish(error: String(localized: "Too much text for this model: select less and ask again."))
                return
            }
            let req = OwlChatRequest(question: q, action: action, context: ctx, snapshot: snap, history: history,
                                     useTools: self.gate.allowsTools(engine.scoreKey), prose: prose)
            do {
                let outcome = try await OwlChatRunner.run(req, engine: engine, model: engine.scoreKey) { ev in
                    if case .text(let t) = ev {
                        Task { @MainActor [weak self] in self?.append(t) }
                    }
                }
                try? await Task.sleep(for: .milliseconds(50))   // let queued text land first
                if var last = self.entries.last, last.role == .owl {
                    last.text = OwlChatRunner.stripThinking(outcome.answer)
                    last.cards = Self.cards(Array(outcome.proposals.prefix(OwlTools.maxProposals)))
                    self.entries[self.entries.count - 1] = last
                    self.refreshCards()
                }
            } catch is CancellationError {
                self.finish(error: String(localized: "Stopped."))
            } catch {
                self.finish(error: AIStatus.describe(error))
            }
        }
    }

    private func append(_ t: String) {
        guard running, var last = entries.last, last.role == .owl else { return }
        last.text += t
        entries[entries.count - 1] = last
    }

    private func finish(error: String) {
        if var last = entries.last, last.role == .owl {
            last.role = .note
            last.text = error
            entries[entries.count - 1] = last
        }
    }

    func stop() { task?.cancel() }

    private static func cards(_ proposals: [OwlEditProposal]) -> [Card] {
        proposals.enumerated().map { i, p in
            Card(id: i, proposal: p,
                 needsShowAll: OwlEditReview.needsShowAll(rows: p.diffLines.map(\.text), charsPerRow: OwlEditReview.fallbackCharsPerRow),
                 firstLine: p.firstLine, lastLine: p.lastLine)
        }
    }

    /// The document changed. One recheck per burst, and only while Ask
    /// Cedric is on screen. A large document is not searched.
    func documentEdited() {
        guard askIsVisible(), entries.contains(where: { !$0.cards.isEmpty }) else { return }
        let now = documentNow()
        if now.large {
            refreshCards()
            return
        }
        guard OwlCardRefresh.shouldRefresh(panelVisible: true, largeDocument: false, extrasPaused: false, hasCards: true) else { return }
        recheck?.cancel()
        recheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(OwlCardRefresh.debounce * 1000)))
            guard !Task.isCancelled else { return }
            self?.refreshCards()
        }
    }

    /// The buffer was replaced (a reload). The proposals were for the previous text.
    func documentReplaced() {
        recheck?.cancel()
        var list = entries
        var changed = false
        for i in list.indices where !list[i].cards.isEmpty {
            list[i].cards = OwlBufferReplacement.kept(list[i].cards.map(\.proposal)).enumerated().map { j, p in
                Card(id: j, proposal: p, needsShowAll: false, firstLine: p.firstLine, lastLine: p.lastLine)
            }
            changed = true
        }
        if changed { entries = list }
    }

    func refreshCards() {
        let now = documentNow()
        var list = entries
        var changed = false
        for i in list.indices {
            guard !list[i].cards.isEmpty else { continue }
            let proposals = list[i].cards.map(\.proposal)
            let states = OwlEditProposal.refresh(proposals, text: now.text, generation: now.generation,
                                                 readOnly: now.readOnly || now.large).states
            for j in list[i].cards.indices {
                let state = j < states.count ? states[j] : OwlEditProposal.ApplyState.stale
                if list[i].cards[j].state != state {
                    list[i].cards[j].state = state
                    changed = true
                }
                if case .ready(let range) = state {
                    let span = OwlEditProposal.lineSpan(range, in: now.lines)
                    if list[i].cards[j].firstLine != span.first || list[i].cards[j].lastLine != span.last {
                        list[i].cards[j].firstLine = span.first
                        list[i].cards[j].lastLine = span.last
                        changed = true
                    }
                }
            }
        }
        if changed { entries = list }
    }

    func noteWidth(entry: UUID, card: Int, charsPerRow: Int) {
        guard let i = entries.firstIndex(where: { $0.id == entry }),
              let j = entries[i].cards.firstIndex(where: { $0.id == card }) else { return }
        let needs = OwlEditReview.needsShowAll(rows: entries[i].cards[j].proposal.diffLines.map(\.text), charsPerRow: charsPerRow)
        guard entries[i].cards[j].needsShowAll != needs else { return }
        entries[i].cards[j].needsShowAll = needs
    }

    func showAll(entry: UUID, card: Int) {
        guard let i = entries.firstIndex(where: { $0.id == entry }),
              let j = entries[i].cards.firstIndex(where: { $0.id == card }) else { return }
        entries[i].cards[j].shownAll = true
    }

    func skipCard(entry: UUID, card: Int) {
        removeCard(entry: entry, card: card, note: String(localized: "Skipped."))
    }

    func askAgain() {
        let q = lastQuestion
        let action = lastAction
        for i in entries.indices { entries[i].cards = [] }
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || action != nil else { return }
        ask(action == nil ? q : "", action: action)
    }

    func applyCard(entry: UUID, card: Int) {
        guard let i = entries.firstIndex(where: { $0.id == entry }),
              let j = entries[i].cards.firstIndex(where: { $0.id == card }) else { return }
        let card = entries[i].cards[j]
        let now = documentNow()
        let state = card.proposal.state(text: now.text, generation: now.generation, readOnly: now.readOnly || now.large)
        entries[i].cards[j].state = state
        let ready = if case .ready = state { true } else { false }
        guard OwlEditReview.applyEnabled(ready: ready, needsShowAll: card.needsShowAll, hasShownAll: card.shownAll) else { return }
        switch apply(card.proposal) {
        case .applied:
            removeCard(entry: entry, card: card.id, note: String(localized: "Applied. Undo puts it back."))
        case .stale:
            entries.append(Entry(role: .note, text: String(localized: "The text changed since Cedric read it, so the edit wasn’t applied.")))
        case .refused:
            entries.append(Entry(role: .note, text: String(localized: "Couldn’t apply this edit here; ask again.")))
        }
        refreshCards()
    }

    private func removeCard(entry: UUID, card: Int, note: String) {
        guard let i = entries.firstIndex(where: { $0.id == entry }) else { return }
        entries[i].cards.removeAll { $0.id == card }
        entries.append(Entry(role: .note, text: note))
    }
}

struct AskCedricView: View {
    @ObservedObject var model: AskCedricModel
    /// Called by Done instead of dismissing, when the view is not in a sheet
    /// (the docked side panel on wide screens).
    var onDone: (() -> Void)? = nil
    /// The iPad side panel, offered as a sheet over the editor instead.
    /// Nil in the sheet itself.
    var onPopOut: (() -> Void)? = nil
    /// A "Line N" citation was tapped. The editor jumps; the text is not changed.
    var onJumpToLine: ((Int) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focused: Bool
    @State private var theme = AppSettings.theme
    @ScaledMetric(relativeTo: .title3) private var owlSize: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var introOwlSize: CGFloat = 52

    private static let endID = "ask.end"

    private var palette: EditorPalette { theme.palette(systemIsDark: colorScheme == .dark) }
    private var colors: AskColors { AskColors(palette) }

    var body: some View {
        let c = colors
        VStack(spacing: 0) {
            header(c)
            Rectangle().fill(c.hairline).frame(height: 1)
                .ignoresSafeArea(.container, edges: .horizontal)
            ScrollViewReader { proxy in
                ScrollView {
                    // A plain VStack: a LazyVStack mis-measured a long,
                    // streamed answer, so its end couldn't be scrolled to.
                    VStack(alignment: .leading, spacing: 14) {
                        if model.entries.isEmpty { intro(c) }
                        ForEach(model.entries) { e in row(e, c).id(e.id) }
                        Color.clear.frame(height: 1).id(Self.endID)
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                // The input bar sits under the scroll view's content, so the
                // last line scrolls clear of it; a soft fade above the bar.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [c.background.opacity(0), c.background], startPoint: .top, endPoint: .bottom)
                            .frame(height: 18)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .ignoresSafeArea(.container, edges: .horizontal)
                        inputBar(c)
                    }
                }
                .onChange(of: model.entries) { _, _ in proxy.scrollTo(Self.endID, anchor: .bottom) }
            }
        }
        .foregroundStyle(c.text)
        .tint(c.accent)
        .background(c.background.ignoresSafeArea())
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
        .environment(\.openURL, OpenURLAction { [onJumpToLine] url in
            guard let line = LineCitations.line(from: url) else { return .systemAction }
            onJumpToLine?(line)
            return .handled
        })
        .presentationBackground(c.background)
        .onReceive(NotificationCenter.default.publisher(for: AppSettings.changed)) { _ in theme = AppSettings.theme }
        .task { await model.prepare() }
    }

    // MARK: Header

    private func header(_ c: AskColors) -> some View {
        HStack(spacing: 10) {
            // One owl at a time: the intro's big one, then this small one.
            if !model.entries.isEmpty {
                Image("Owl", bundle: .owlink).resizable().scaledToFit()
                    .frame(width: owlSize, height: owlSize)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "Ask Cedric")).font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let t = model.engineTitle {
                    Text(t).font(.caption).foregroundStyle(c.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let onPopOut {
                Button(action: onPopOut) {
                    Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                        .font(.body)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(c.accent)
                .accessibilityLabel(String(localized: "Show as Sheet"))
                .accessibilityIdentifier("ask.popOut")
            }
            Button {
                model.stop()
                if let onDone { onDone() } else { dismiss() }
            } label: {
                Text(String(localized: "Done")).font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(c.accent)
            .accessibilityIdentifier("ask.done")
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6)
        // Full width: the bar's colour runs under a side inset (the folded
        // iPhone Duo's vertical bar left a darker strip), the text stays inside.
        .background(c.bar.ignoresSafeArea(.container, edges: [.horizontal, .top]))
    }

    // MARK: Empty state

    private func intro(_ c: AskColors) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                Image("Owl", bundle: .owlink).resizable().scaledToFit()
                    .frame(width: introOwlSize, height: introOwlSize)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Ask about this document.")).font(.headline)
                    if let t = model.engineTitle {
                        Text(String(localized: "Answered by \(t).")).font(.footnote).foregroundStyle(c.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let why = model.unavailable {
                VStack(alignment: .leading, spacing: 8) {
                    Text(why).font(.footnote).foregroundStyle(c.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "Open Settings")) { model.openSettings() }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
            }
            if !model.actions.isEmpty {
                section(String(localized: "Quick actions"), c)
                FlowButtons(actions: model.actions, prose: model.prose, colors: c) { model.ask("", action: $0) }
                    .disabled(model.unavailable != nil)
            }
            section(String(localized: "Try asking…"), c)
            VStack(spacing: 8) {
                ForEach(examples, id: \.self) { q in
                    Button { model.ask(q) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "text.bubble").foregroundStyle(c.accent).accessibilityHidden(true)
                            Text(q).font(.subheadline).multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .background(c.chipFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(c.hairline, lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(c.text)
                    .accessibilityIdentifier("ask.example")
                }
            }
            .disabled(model.unavailable != nil)
            .opacity(model.unavailable != nil ? 0.5 : 1)
        }
    }

    private func section(_ title: String, _ c: AskColors) -> some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(c.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    /// A few starter questions, asked as typed.
    private var examples: [String] {
        if model.prose {
            return [String(localized: "What is this about, in two sentences?"),
                    String(localized: "Which parts are unclear or wordy?"),
                    String(localized: "Suggest a better opening line."),
                    String(localized: "What questions might a reader still have?")]
        }
        return [String(localized: "What does this file do?"),
                String(localized: "Are there any bugs here?"),
                String(localized: "How could this be simpler?"),
                String(localized: "What should I test first?")]
    }

    // MARK: Conversation

    @ViewBuilder private func row(_ e: AskCedricModel.Entry, _ c: AskColors) -> some View {
        switch e.role {
        case .user:
            Text(e.text).font(.body)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(c.userBubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)
        case .owl:
            VStack(alignment: .leading, spacing: 8) {
                if e.text.isEmpty && model.running {
                    ProgressView().accessibilityIdentifier("ask.thinking")
                } else {
                    Text(.init(LineCitations.linked(e.text))).font(.body).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .tint(c.accent)
                        .accessibilityIdentifier("ask.answer")
                }
                ForEach(e.cards) { card in
                    AskEditCard(entry: e.id, card: card, count: e.cards.count, colors: c,
                                apply: { model.applyCard(entry: e.id, card: card.id) },
                                skip: { model.skipCard(entry: e.id, card: card.id) },
                                showAll: { model.showAll(entry: e.id, card: card.id) },
                                askAgain: { model.askAgain() },
                                noteWidth: { model.noteWidth(entry: e.id, card: card.id, charsPerRow: $0) })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            Text(e.text).font(.footnote).foregroundStyle(c.secondary)
        }
    }

    // MARK: Input

    private func inputBar(_ c: AskColors) -> some View {
        let empty = model.question.trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(alignment: .bottom, spacing: 4) {
            TextField(String(localized: "Ask Cedric…"), text: $model.question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit { model.ask(model.question) }
                .padding(.leading, 14).padding(.vertical, 11)
                .accessibilityIdentifier("ask.field")
            Group {
                if model.running {
                    Button { model.stop() } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .foregroundStyle(c.accent)
                    .accessibilityLabel(String(localized: "Stop"))
                } else {
                    Button { model.ask(model.question) } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .foregroundStyle(empty || model.unavailable != nil ? c.secondary.opacity(0.6) : c.accent)
                    .disabled(empty || model.unavailable != nil)
                    .accessibilityLabel(String(localized: "Send"))
                    .accessibilityIdentifier("ask.send")
                }
            }
            .buttonStyle(.plain)
            .padding(.trailing, 2)
        }
        .background(c.field, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(focused ? c.accent.opacity(0.7) : c.hairline, lineWidth: 1))
        // Close to the bottom safe area (the home indicator), riding the keyboard when it is up.
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
        .background(c.bar.ignoresSafeArea(.container, edges: [.bottom, .horizontal]).ignoresSafeArea(.keyboard, edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(c.hairline).frame(height: 1).ignoresSafeArea(.container, edges: .horizontal) }
    }
}

/// One proposed edit: the reason, the before/after lines, Apply and Skip.
/// Apply stays off until the proposal matches the live document and a long
/// replacement has been opened. Read-only never applies.
struct AskEditCard: View {
    let entry: UUID
    let card: AskCedricModel.Card
    let count: Int
    let colors: AskColors
    var apply: () -> Void
    var skip: () -> Void
    var showAll: () -> Void
    var askAgain: () -> Void
    var noteWidth: (Int) -> Void

    private var ready: Bool { if case .ready = card.state { return true }; return false }
    private var canApply: Bool { OwlEditReview.applyEnabled(ready: ready, needsShowAll: card.needsShowAll, hasShownAll: card.shownAll) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold))
            if !card.proposal.reason.isEmpty {
                Text(card.proposal.reason).font(.footnote).foregroundStyle(colors.secondary)
            }
            if OwlEditInvisibles.contains(card.proposal.original) || OwlEditInvisibles.contains(card.proposal.replacement) {
                Text(OwlEditInvisibles.warning).font(.footnote.weight(.semibold)).foregroundStyle(.purple)
            }
            diff
            if card.needsShowAll && !card.shownAll {
                Button(String(localized: "Show all"), action: showAll)
                    .font(.footnote)
                    .accessibilityIdentifier("ask.showAll")
            }
            if case .stale = card.state {
                Text(String(localized: "Text changed or isn’t unique; ask again.")).font(.footnote).foregroundStyle(.orange)
                Button(String(localized: "Ask Again"), action: askAgain).font(.footnote)
            } else if case .readOnly = card.state {
                Text(String(localized: "This document is read-only, so the change can’t be applied.")).font(.footnote).foregroundStyle(.orange)
            }
            HStack {
                Button(String(localized: "Apply"), action: apply)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canApply)
                    .accessibilityIdentifier("ask.apply")
                Button(String(localized: "Skip"), action: skip)
                    .accessibilityIdentifier("ask.skip")
            }
            .font(.footnote)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.field, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(colors.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("ask.card")
    }

    private var title: String {
        let lines = card.firstLine == card.lastLine
            ? String(localized: "line \(card.firstLine)")
            : String(localized: "lines \(card.firstLine)–\(card.lastLine)")
        if count > 1 { return String(localized: "Change \(card.id + 1) of \(count), \(lines)") }
        return card.firstLine == card.lastLine
            ? String(localized: "Proposed change to line \(card.firstLine)")
            : String(localized: "Proposed change to lines \(card.firstLine)–\(card.lastLine)")
    }

    private var label: String {
        var text = title
        if !card.proposal.reason.isEmpty { text += ": " + card.proposal.reason }
        text += ". " + card.proposal.spokenDiff
        return text
    }

    private var diff: some View {
        let rows = card.proposal.diffLines
        let cap: CGFloat = card.shownAll || !card.needsShowAll ? 220 : CGFloat(OwlEditReview.visibleRows) * 18
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let rendered = OwlEditInvisibles.render(row.text).text
                    let prefix = row.kind == .removed ? "- " : row.kind == .added ? "+ " : "  "
                    Text(prefix + rendered)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(row.kind == .removed ? Color.red.opacity(0.18) : row.kind == .added ? Color.green.opacity(0.18) : Color.clear)
                }
            }
            .background(GeometryReader { geo in
                Color.clear.preference(key: AskDiffWidth.self, value: geo.size.width)
            })
        }
        .frame(maxHeight: cap)
        .onPreferenceChange(AskDiffWidth.self) { width in
            let sample = ("0" as NSString).size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width
            guard sample > 0.5, width > 20 else { return }
            noteWidth(max(8, Int(width / sample)))
        }
    }
}

private struct AskDiffWidth: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The view's colours, from the editor theme's palette.
struct AskColors {
    let background, text, secondary, accent, bar, field, hairline, chipFill, userBubble: Color

    init(_ p: EditorPalette) {
        let fg = Color(uiColor: UIColor(hex: p.foreground))
        let accent = Color(uiColor: UIColor(hex: p.caret))
        background = Color(uiColor: UIColor(hex: p.background))
        text = fg
        secondary = Color(uiColor: UIColor(hex: p.gutterForeground))
        self.accent = accent
        bar = Color(uiColor: UIColor(hex: p.statusBar))
        field = Color(uiColor: UIColor(hex: p.gutterBackground))
        hairline = fg.opacity(p.isDark ? 0.18 : 0.14)
        chipFill = accent.opacity(p.isDark ? 0.14 : 0.08)
        userBubble = accent.opacity(p.isDark ? 0.24 : 0.14)
    }
}

/// The quick actions as a wrapping row of chips.
struct FlowButtons: View {
    let actions: [OwlQuickAction]
    let prose: Bool
    let colors: AskColors
    let tap: (OwlQuickAction) -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(actions, id: \.self) { a in
                Button { tap(a) } label: {
                    Text(a.title(prose: prose)).font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .frame(minHeight: 44)
                        .background(colors.chipFill, in: Capsule())
                        .overlay(Capsule().strokeBorder(colors.hairline, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(colors.text)
            }
        }
        .opacity(enabled ? 1 : 0.5)
    }
}

/// Lays its children out left to right, wrapping onto new rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [(range: Range<Int>, height: CGFloat, sizes: [CGSize])] {
        var result: [(range: Range<Int>, height: CGFloat, sizes: [CGSize])] = []
        var start = 0, x: CGFloat = 0, h: CGFloat = 0
        var sizes: [CGSize] = []
        for (i, v) in subviews.enumerated() {
            var s = v.sizeThatFits(.unspecified)
            if s.width > width { s = v.sizeThatFits(ProposedViewSize(width: width, height: nil)); s.width = min(s.width, width) }
            if i > start && x + spacing + s.width > width {
                result.append((start..<i, h, sizes))
                start = i; x = 0; h = 0; sizes = []
            }
            x += (i > start ? spacing : 0) + s.width
            h = max(h, s.height)
            sizes.append(s)
        }
        if start < subviews.count { result.append((start..<subviews.count, h, sizes)) }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rs = rows(width, subviews)
        let used = rs.map { $0.sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max($0.sizes.count - 1, 0)) }.max() ?? 0
        let height = rs.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rs.count - 1, 0))
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for r in rows(bounds.width, subviews) {
            var x = bounds.minX
            for (k, i) in r.range.enumerated() {
                let s = r.sizes[k]
                subviews[i].place(at: CGPoint(x: x, y: y + (r.height - s.height) / 2), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += r.height + spacing
        }
    }
}
