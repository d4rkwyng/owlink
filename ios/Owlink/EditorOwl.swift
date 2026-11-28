import Foundation
import CedricCore
import CedricAI

/// Cedric's hints for one document: the offline rules after every pause in
/// typing (on by default), and the optional AI engine (Apple Intelligence,
/// the built-in model on a device, or a LAN server) only when Cedric AI is
/// turned on in Settings, or when asked with "Check with Cedric". Ranges
/// come back relative to the context's text; `apply` converts them and
/// checks the text there is still what the provider saw.
@MainActor
final class EditorOwl {
    struct Shown: Equatable {
        var hint: OwlHint
        /// Where `hint.range` starts in the document.
        var offset: Int
        var generation: Int
        var seen: String?
    }

    let documentID = UUID()
    private let rules = RulesHintProvider()
    private(set) var hints: [Shown] = []
    private(set) var current = 0
    private var dismissed = Set<String>()
    private var task: Task<Void, Never>?
    private var aiTask: Task<Void, Never>?
    private var lastAICheck = Date.distantPast
    var onChange: (() -> Void)?
    /// For the "Check with Cedric" result when nothing was found.
    var onNote: ((String) -> Void)?

    var visible: Shown? { hints.indices.contains(current) ? hints[current] : nil }

    struct Snapshot {
        var text: NSString
        var visible: NSRange
        var selection: NSRange
        var fileName: String?
        var language: Language
        var generation: Int
        var facts: OwlDocumentFacts
        /// Over the auto-review cap (100 KB or 2,000 lines, `AutoReviewCap`):
        /// no automatic AI check; the offline rules (a window only) carry on.
        var autoReviewCapped = false
    }

    /// The offline rules, 0.8 s after the last edit; then the AI, if it is
    /// on and automatic, no more often than its interval.
    func schedule(_ snap: @escaping () -> Snapshot) {
        task?.cancel()
        guard AppSettings.owlHints else { if !hints.isEmpty { hints = []; onChange?() }; return }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            let s = snap()
            let window = Self.window(s, documentID: self.documentID)
            let found = self.rules.check(window.context, facts: s.facts)
            self.merge(found, offset: window.offset, generation: s.generation, text: s.text, source: "rules")
            let ai = AIStore.load()
            if ai.isUsable, ai.automaticChecks, !s.autoReviewCapped, Date().timeIntervalSince(self.lastAICheck) >= ai.minInterval {
                self.askAI(snap, quiet: true)
            }
        }
    }

    /// "Check with Cedric": the AI engine now, whatever the interval.
    func askAI(_ snap: @escaping () -> Snapshot, quiet: Bool = false) {
        aiTask?.cancel()
        // Asked for (Check with Cedric) may load the built-in model; the
        // automatic check only uses one already in memory (0.5.3).
        aiTask = BuiltInLoad.$intent.withValue(quiet ? .automatic : .userAsked) { Task { [weak self] in
            guard !Task.isCancelled, let self else { return }
            let s = snap()
            if quiet && s.autoReviewCapped { return }
            let window = Self.window(s, documentID: self.documentID)
            guard HintPrompt.hasEnoughText(window.context.text) else {
                if !quiet { self.onNote?(String(localized: "Type a little more and Cedric will take a look.")) }
                return
            }
            self.lastAICheck = Date()
            var settings = AIStore.load()
            if quiet && (!settings.isUsable || !settings.automaticChecks) { return }
            if !settings.isUsable {
                // Asked for: use whatever is ready, as Ask Cedric does.
                guard let ready = OwlChatSetup.chatSettings(settings, appleAvailable: AppleFoundationModelsProvider.isAvailable,
                                                        builtInInstalled: !BuiltInEngine().installedModels.isEmpty) else {
                    if !quiet { self.onNote?(String(localized: "No AI engine is ready. Set one up in Settings › Cedric AI.")) }
                    return
                }
                settings = ready
            }
            let engine = AIEngines.engine(for: settings)
            guard engine.isAvailable, let provider = await engine.makeProvider(model: settings.model) else {
                if !quiet { self.onNote?(engine.unavailableReason ?? String(localized: "The AI engine isn’t ready.")) }
                return
            }
            if quiet && AIStore.load() != settings { return }
            let found = await provider.hints(for: window.context)
            guard !Task.isCancelled else { return }
            if found.isEmpty, !quiet { self.onNote?(String(localized: "Cedric found nothing to point out.")) }
            self.merge(found, offset: window.offset, generation: s.generation, text: s.text, source: provider.name)
        } }
    }

    static func window(_ s: Snapshot, documentID: UUID) -> OwlContextWindow {
        OwlContextWindow(text: s.text, visible: s.visible, selection: s.selection, fileName: s.fileName,
                         language: s.language.rawValue, documentID: documentID, editGeneration: s.generation)
    }

    private func merge(_ found: [OwlHint], offset: Int, generation: Int, text: NSString, source: String) {
        let isRules = source == "rules"
        // Rules replace the rules' hints, an AI check the AI's.
        let kept = hints.filter { ($0.hint.source == "rules") != isRules }
        var fresh: [Shown] = []
        for h in found where !dismissed.contains(h.id) {
            var seen: String?
            if let r = h.range {
                let abs = NSRange(location: r.location + offset, length: r.length)
                guard abs.location >= 0, NSMaxRange(abs) <= text.length else { continue }
                seen = text.substring(with: abs)
            }
            fresh.append(Shown(hint: h, offset: offset, generation: generation, seen: seen))
        }
        // The rules' hints first, then the AI's; at most 4 in all.
        let list = Array((isRules ? fresh + kept : kept + fresh).prefix(4))
        if list != hints {
            let keep = visible?.hint.id
            hints = list
            current = list.firstIndex { $0.hint.id == keep } ?? 0
            onChange?()
        }
    }

    func dismissCurrent() {
        guard let v = visible else { return }
        dismissed.insert(v.hint.id)
        hints.remove(at: current)
        if current >= hints.count { current = 0 }
        onChange?()
    }

    func showNext() {
        guard !hints.isEmpty else { return }
        current = (current + 1) % hints.count
        onChange?()
    }

    /// The fix's document range and replacement, if the text there is
    /// still what the provider saw.
    func fix(in text: NSString) -> (range: NSRange, replacement: String)? {
        guard let v = visible, let r = v.hint.range, let rep = v.hint.replacement else { return nil }
        let abs = NSRange(location: r.location + v.offset, length: r.length)
        guard NSMaxRange(abs) <= text.length, text.substring(with: abs) == v.seen else { return nil }
        return (abs, rep)
    }

    func cancel() { task?.cancel(); aiTask?.cancel() }
}
