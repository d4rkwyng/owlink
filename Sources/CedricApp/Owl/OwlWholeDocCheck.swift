import AppKit
import CedricCore
import CedricAI

/// CEDRIC_OWL_CHECK_CHAT=wholedoc (with CEDRIC_OWL_CHECK and the fake
/// engine, CEDRIC_AI_FAKE): Summarise on a Markdown file too long for one
/// request. The chip says "Whole document (N lines)", never "trimmed to
/// fit"; every line is read in parts; one answer shows first, with the
/// parts' notes collapsed under it ("▸ Section notes (n)"), which open and
/// close.
@MainActor
enum OwlWholeDocCheck {
    static func check(_ ok: Bool, _ what: String) { OwlCheck.check(ok, what) }

    static func run(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window else { OwlCheck.finish(out); return }
        let total = (tab.text as NSString).components(separatedBy: "\n").filter { !$0.isEmpty }.count
        OwlCheck.key(window, "/", code: 44, [.command, .option])
        OwlCheck.after(0.3) {
            guard let chat = tab.owlChat, chat.isShown else { check(false, "⌥⌘/ opens Ask Cedric"); OwlCheck.finish(out); return }
            chat.selectScope(.wholeDocument)
            chat.refresh()
            let chip = chat.scopePopup.selectedItem?.title ?? ""
            check(chip.hasPrefix("Whole document (") && !chip.contains("trimmed"), "the chip before asking: \(chip)")
            guard let b = chat.actionButtons[.summarise], !b.isHidden else {
                check(false, "Summarise is offered for Markdown"); OwlCheck.finish(out); return
            }
            OwlCheck.click(b)
            OwlChatCheck.waitDone(chat, timeout: 60) { _ in
                OwlCheck.after(0.3) {
                    let text = chat.transcriptText
                    let chipAfter = chat.scopePopup.selectedItem?.title ?? ""
                    check(chipAfter == "Whole document (\(total) lines)", "the chip after: \(chipAfter)")
                    check(!text.contains("not reviewed") && !text.contains("trimmed to fit"), "no truncation note")
                    check(text.contains("▸ Section notes ("), "the section notes are collapsed under the answer")
                    check(!text.contains("Lines 1–"), "and closed: no part's notes show")
                    OwlCheck.snapshot(chat.panel, "\(out)/wholedoc-1-collapsed.png") {
                        let index = OwlChatStore.shared.history(chat.docID!).count - 1
                        chat.toggleSectionNotes(index)
                        let open = chat.transcriptText
                        check(open.contains("▾ Section notes (") && open.contains("Lines 1–"), "Section notes open, part by part")
                        let answerAt = (open as NSString).range(of: "Cedric\n").location
                        let notesAt = (open as NSString).range(of: "▾ Section notes").location
                        check(answerAt != NSNotFound && answerAt < notesAt, "the one answer comes first")
                        OwlCheck.snapshot(chat.panel, "\(out)/wholedoc-2-expanded.png") {
                            chat.toggleSectionNotes(index)
                            check(chat.transcriptText.contains("▸ Section notes ("), "and close again")
                            chat.close()
                            OwlCheck.finish(out)
                        }
                    }
                }
            }
        }
    }
}
