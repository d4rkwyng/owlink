import AppKit
import CedricCore

/// CEDRIC_CHECK=large: large mode end to end, with the owl on. A file like
/// Derek's (one 636 K-character base64 line, plus a few lines with trailing
/// spaces the owl's rules would flag): large mode is on at open, the info
/// bar shows, colouring and spell check are paused, the owl's scheduled
/// rules never run and the AI is never fed; typing at the end stays fast;
/// clicking the owl runs the rules once; "Turn On Anyway" brings the extras
/// back; pasting a long line into a small tab turns large mode on.
extension DevChecks {
    static func largeDocument(_ app: AppDelegate) {
        Settings.shared.owlOverride = true
        OwlController.assumeVisible = true
        let hub = OwlHub.shared
        hub.coordinator.queryInterval = 0.3
        hub.coordinator.typingPause = 0.2
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
        let blob = String((0..<636_000).map { _ in alphabet[Int(rng.next() % 64)] })
        let text = (1...6).map { "line \($0) with trailing spaces   " }.joined(separator: "\n") + "\n" + blob
        let file = write("big-guide.txt", text)
        let t0 = DevHooks.now()
        guard let tab = app.open(file) else { expect(false, "open"); finish(); return }
        let openMs = (DevHooks.now() - t0) * 1000
        sized(tab)
        let queriesAtOpen = hub.coordinator.queryCount
        var typed: [Double] = []
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                tab.window?.makeKeyAndOrderFront(nil)
                expect(openMs < 300, "opens in under 300 ms", String(format: "%.0f ms", openMs))
                expect(tab.isLargeDocument && tab.largeReason == .longLine, "large mode on (long line)")
                expect(!tab.largeBar.isHidden, "the info bar shows")
                expect(tab.largeBar.label.stringValue.hasPrefix("Very long lines"), "…and says why", tab.largeBar.label.stringValue)
                expect(tab.textView.contentStorage?.chunkLimit == LargeDocument.chunkLength, "TextKit sees the long line in chunks")
                expect(tab.colorizer.paused, "colouring paused")
                expect(!tab.textView.isContinuousSpellCheckingEnabled, "spell checking off")
                expect(tab.owl != nil && tab.owlIdleForSpeed, "the owl is on but idle")
                expect(tab.text == text, "the text is untouched (no inserted breaks)")
            },
            { next in
                // Type at the end of the long line, through real key events.
                tab.window?.makeFirstResponder(tab.textView)
                tab.textView.setSelectedRange(NSRange(location: (tab.text as NSString).length, length: 0))
                tab.reveal(tab.textView.selectedRange())
                for c in "xyzzy" {
                    let s = DevHooks.now()
                    key(String(c))
                    tab.window?.displayIfNeeded()
                    typed.append((DevHooks.now() - s) * 1000)
                }
                // Long enough for the owl's schedule and the AI feed to come due.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { next() }
            },
            sync {
                expect(tab.text.hasSuffix("xyzzy"), "typed text lands at the end", String(tab.text.suffix(12)))
                let median = typed.sorted()[typed.count / 2]
                expect(median < 16, "a keystroke takes under 16 ms", String(format: "median %.1f ms", median))
                expect(hub.coordinator.queryCount == queriesAtOpen, "the owl's rules never ran on their own",
                       "\(hub.coordinator.queryCount) queries")
                expect(tab.owl?.bubble == nil, "no bubble")
                expect(tab.owl?.owl.pose != .thinking, "the owl isn't thinking")
                expect(hub.ai.largeDocuments.contains(tab.doc.id), "the AI has the tab marked large (no model load)")
            },
            snapshot("large-infobar.png"),
            { next in
                // Clicked: the rules look once, at the visible window (the
                // top, where the trailing spaces are).
                tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
                tab.scrollToLine(0)
                tab.window?.displayIfNeeded()
                guard let owl = tab.owl?.owl, let w = owl.window else { next(); return }
                // A press and release on the owl, straight to his view (the
                // window can't route clicks while the app is inactive).
                let p = owl.convert(NSPoint(x: owl.bounds.midX, y: owl.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: w.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                                                     pressure: type == .leftMouseDown ? 1 : 0) else { continue }
                    if type == .leftMouseDown { owl.mouseDown(with: e) } else { owl.mouseUp(with: e) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() }
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                expect(hub.coordinator.queryCount == queriesAtOpen + 1, "clicking the owl runs the rules once",
                       "\(hub.coordinator.queryCount - queriesAtOpen)")
                let title = tab.owl?.presentedHint?.hint.title ?? "-"
                expect(tab.owl?.bubble != nil && title.contains("end in spaces"), "…and he says what he found", title)
            },
            snapshot("large-owl-clicked.png"),
            sync {
                tab.owl?.hideBubble()
                click(tab.largeBar.button, at: NSPoint(x: tab.largeBar.button.bounds.midX, y: tab.largeBar.button.bounds.midY))
                expect(tab.largeBar.isHidden, "Turn On Anyway hides the bar")
                expect(!tab.colorizer.paused && !tab.owlIdleForSpeed, "…and brings colouring and the owl back")
                expect(!hub.ai.largeDocuments.contains(tab.doc.id), "…and the AI may look again")
                expect(tab.textView.contentStorage?.chunkLimit != nil, "…while TextKit keeps the chunks")
            },
            { next in
                // A paste of a long line into a small untitled tab.
                app.newTab(nil)
                guard let small = app.tabs.last, small !== tab else { next(); return }
                sized(small)
                small.textView.insertText("hello\n", replacementRange: NSRange(location: 0, length: 0))
                expect(!small.isLargeDocument, "a small tab isn't large")
                small.textView.insertText(String(blob.prefix(30_000)), replacementRange: small.textView.selectedRange())
                expect(small.extrasPaused, "a long paste pauses the extras at once")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    expect(small.isLargeDocument && !small.largeBar.isHidden, "…and turns large mode on")
                    expect(small.textView.contentStorage?.chunkLimit == LargeDocument.chunkLength, "…with chunks")
                    expect(small.doc.language == .plain, "no language sniff over the paste", small.doc.language.rawValue)
                    let s = DevHooks.now()
                    small.textView.insertText("q", replacementRange: small.textView.selectedRange())
                    small.window?.displayIfNeeded()
                    expect((DevHooks.now() - s) * 1000 < 16, "typing after the paste is fast")
                    next()
                }
            },
            snapshot("large-pasted.png"),
        ]
        steps += steps2
        run(steps)
    }
}
