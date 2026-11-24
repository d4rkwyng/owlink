import AppKit
import CedricCore

extension OwlChatPanel {
    /// Ask Cedric "Fix the spelling mistakes" (OwlSpellingIntent): opens
    /// the offline Fix Typos step-through (NSSpellChecker; nothing sent
    /// anywhere) instead of asking the model for a free-form edit. The
    /// question and a note on what happened go into the chat.
    ///
    /// No model is involved: Fix Typos shows the spell checker's own order.
    /// (Cedric's pick among plausible guesses, `OwlSpellingChoice`, is for
    /// 0.6, through local generation that enforces its candidate grammar.)
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
