import AppKit
import CedricCore

extension OwlChatPanel {
    /// Ask Cedric "Fix the spelling mistakes" (OwlSpellingIntent): opens
    /// the offline Fix Typos step-through (NSSpellChecker; nothing sent
    /// anywhere) instead of asking the model for a free-form edit. The
    /// question and a note on what happened go into the chat.
    ///
    /// SEAM (not wired in 0.5.3): Cedric's pick among several plausible
    /// guesses (`OwlSpellingPicker.pick`, which only reorders Fix Typos'
    /// suggestions) would hook in here, passing an engine only when one is
    /// already in use for this Ask. This route doesn't use an engine, so
    /// Fix Typos shows the spell checker's own order.
    func routeToFixTypos(_ question: String, tab: EditorWindowController, id: UUID) {
        OwlChatStore.shared.append(OwlChatEntry(role: .user, text: question), to: id)
        if tab.spellingChecksThisDocument {
            OwlChatStore.shared.append(OwlChatEntry(role: .note, text: OwlSpellingIntent.routedNote), to: id)
            tab.startSpellStep()
        } else {
            OwlChatStore.shared.append(OwlChatEntry(role: .note, text: OwlSpellingIntent.notCheckedNote), to: id)
        }
    }
}
