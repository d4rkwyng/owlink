import AppKit
import CedricCore

/// CEDRIC_CHECK=editedtitle: unsaved edits mark the window title (and so
/// the native tab's label) with a trailing • beside AppKit's edited dot;
/// save, and undo or redo back to the saved text, clear both. A line-ending
/// change stays unsaved until saved. An untitled tab typed in and undone
/// back to empty is clean again.
@MainActor
extension DevChecks {
    static func editedTitle(_ app: AppDelegate) {
        let a = app.open(write("edited.txt", "owl\n"))!
        let b = app.open(write("clean.txt", "hoot\n"))!
        sized(a)
        var untitled: EditorWindowController!
        func disk(_ t: EditorWindowController) -> String { (try? String(contentsOf: t.doc.fileURL!, encoding: .utf8)) ?? "-" }
        func state(_ t: EditorWindowController) -> String {
            "title \(t.window?.title.debugDescription ?? "-") edited \(t.window?.isDocumentEdited ?? false) dirty \(t.doc.isDirty) text \(t.text.debugDescription)"
        }
        func clean(_ t: EditorWindowController) -> Bool {
            !t.doc.isDirty && t.window?.isDocumentEdited == false && t.window?.title == t.doc.displayName
                && t.window?.accessibilityTitle() == t.doc.displayName
        }
        func marked(_ t: EditorWindowController) -> Bool {
            t.doc.isDirty && t.window?.isDocumentEdited == true && t.window?.title == t.doc.displayName + " •"
                && t.window?.accessibilityTitle() == t.doc.displayName + ", " + String(localized: "Edited")
        }
        let settle: (@escaping () -> Void) -> Void = { next in DispatchQueue.main.async { next() } }
        run([
            sync {
                expect(a.window?.title == "edited.txt" && a.window?.isDocumentEdited == false, "an opened file is titled by its name, not edited", state(a))
                expect(clean(a) && clean(b), "both tabs are clean", state(a) + " | " + state(b))
                focus(a)
                a.textView.setSelectedRange(NSRange(location: 0, length: 0))
                type("!")
            },
            sync {
                expect(marked(a), "typing marks the title with • and sets the edited dot", state(a))
                expect(a.doc.displayName == "edited.txt", "the name itself has no mark", a.doc.displayName)
                expect(clean(b), "the other tab stays clean", state(b))
                expect(a.save(), "⌘S saves")
            },
            sync {
                expect(clean(a) && disk(a) == "!owl\n", "saving clears the mark and the dot", state(a))
                type("?")
            },
            sync {
                expect(marked(a), "typing again marks it", state(a))
                key("z", [.command])
            },
            settle,
            sync {
                expect(a.text == "!owl\n" && clean(a), "⌘Z back to the saved text clears the mark and the dot", state(a))
                key("z", [.command, .shift])
            },
            settle,
            sync {
                expect(a.text == "!?owl\n" && marked(a), "⇧⌘Z away from it marks it again", state(a))
                key("z", [.command])
            },
            settle,
            sync {
                expect(clean(a), "and ⌘Z clears it again", state(a))
                a.convertLineEndings(to: .crlf)
                expect(marked(a), "converting line endings marks it (applied on save)", state(a))
                type("x")
            },
            sync {
                key("z", [.command])
            },
            settle,
            sync {
                expect(a.text == "!owl\n" && marked(a), "undoing the typing keeps the line-ending change unsaved", state(a))
                expect(a.save(), "⌘S saves")
            },
            sync {
                expect(clean(a) && disk(a) == "!owl\r\n", "saved as CRLF: clean", state(a) + " disk " + disk(a).debugDescription)
                app.newTab(nil)
                untitled = app.tabs.last
                focus(untitled)
                expect(untitled.doc.fileURL == nil && clean(untitled), "a new untitled tab is clean", state(untitled))
                type("u")
            },
            sync {
                expect(marked(untitled), "typing in it marks it", state(untitled))
                key("z", [.command])
            },
            settle,
            sync {
                expect(untitled.text.isEmpty && clean(untitled), "⌘Z back to empty clears the mark", state(untitled))
                // A buffer unsaved by definition (session restore, a file gone from disk).
                untitled.doc.markDirtyFromSession()
                untitled.updateTitle()
                expect(marked(untitled), "a restored unsaved buffer is marked", state(untitled))
                // For the picture: one edited tab beside a clean one.
                focus(a)
                a.textView.setSelectedRange(NSRange(location: 0, length: 0))
                type("draft ")
            },
            sync {
                expect(marked(a) && clean(b), "an edited tab beside a clean one", state(a) + " | " + state(b))
            },
            snapshot("edited-tab.png"),
        ])
    }
}
