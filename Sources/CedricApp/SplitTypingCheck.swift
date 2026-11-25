import AppKit
import CedricCore

/// CEDRIC_CHECK=splittyping: typing in a chunked large-mode tab right after
/// the split is closed. The QA monkey's hang, cut down to its nine steps
/// (0.5.4 QA, seeds 213314022/213314023): Base64 Encode a 5 MB log (one
/// 7 M-character line), undo, redo, type, Add Next Occurrence, split,
/// unsplit, type, type. TextKit fixes the selection up from inside the
/// edit (NSTextContentStorage synchronizeTextLayoutManagers), the window
/// tells the owl the caret moved, and the owl used to ask the primary pane
/// for its visible characters there: NSTextLayoutManager
/// ensureLayoutForBounds walked the chunks from inside the edit and never
/// came back. A watchdog thread fails the check (instead of hanging) when
/// the main thread stops answering for 10 s.
extension DevChecks {
    static func splitTypingCheck(_ app: AppDelegate) {
        Settings.shared.owlOverride = true
        OwlController.assumeVisible = true
        final class Ping: @unchecked Sendable { let lock = NSLock(); var last = Date(); var step = "open" }
        let ping = Ping()
        Thread {
            while true {
                DispatchQueue.main.async { ping.lock.withLock { ping.last = Date() } }
                Thread.sleep(forTimeInterval: 0.25)
                let (since, step) = ping.lock.withLock { (Date().timeIntervalSince(ping.last), ping.step) }
                if since > 10 {
                    print("check: FAIL the main thread is stuck (\(Int(since)) s without answering) after: \(step)")
                    print("check: done (watchdog: the passes so far aren't counted), 1 failed")
                    fflush(stdout)
                    exit(1)
                }
            }
        }.start()
        func mark(_ s: String) { ping.lock.withLock { ping.step = s } }

        var log = ""
        log.reserveCapacity(5_300_000)
        var i = 0
        while log.utf8.count < 5 * 1024 * 1024 {
            log += "2026-11-24T10:\(String(format: "%02d:%02d", (i / 60) % 60, i % 60)).\(String(format: "%03d", i % 1000))Z INFO worker-\(i % 16) request id=\(i) status=\(i % 17 == 0 ? 500 : 200) path=/api/items/\(i % 977)\n"
            i += 1
        }
        guard let tab = app.open(write("server.log", log)) else { expect(false, "open"); finish(); return }
        sized(tab)
        final class Timings: @unchecked Sendable { var ms: [String: Double] = [:] }
        let timings = Timings()
        final class Viewport: @unchecked Sendable { var range: NSRange?; var reported = 0; var rechecks = 0; var looks = 0; var bottom: CGFloat? }
        let viewport = Viewport()
        /// TextKit has laid out the viewport for where the primary pane is
        /// scrolled to now (its viewport lags a scroll by a pass).
        func viewportLaidOutAtTop() -> Bool {
            let tv = tab.primaryTextView
            guard let tlm = tv.textLayoutManager, tv.viewportCharacterRange != nil else { return false }
            // viewportBounds is in the text container's coordinates.
            let vb = tlm.textViewportLayoutController.viewportBounds.offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
            let visible = tv.visibleRect
            return vb.minY <= visible.minY && vb.maxY >= visible.maxY
        }
        func timed(_ name: String, _ f: () -> Void) {
            mark(name)
            let t0 = DevHooks.now()
            f()
            timings.ms[name] = (DevHooks.now() - t0) * 1000
        }
        /// Typing after the unsplit, timed through the owl's put-off caret
        /// look (it runs on a later main-queue turn): the keys must reach the
        /// owl from inside the edit, and the look must have finished.
        func typedToOwl(_ name: String, _ f: @escaping () -> Void) -> (@escaping () -> Void) -> Void {
            { next0 in
                nonisolated(unsafe) let next = next0
                guard let owl = tab.owl else { expect(false, "the owl is on"); next(); return }
                mark(name)
                let inEdit = owl.caretMovesInEdit, looks = owl.caretLooks
                let t0 = DevHooks.now()
                f()
                func settle(_ turns: Int) {
                    DispatchQueue.main.async {
                        guard owl.caretLookPending, turns < 50 else {
                            timings.ms[name] = (DevHooks.now() - t0) * 1000
                            expect(owl.caretMovesInEdit > inEdit, "\(name): the caret move reached the owl from inside the edit",
                                   "\(owl.caretMovesInEdit - inEdit) calls in an edit")
                            expect(!owl.caretLookPending && owl.caretLooks > looks, "\(name): the owl's caret look ran after the edit",
                                   "pending \(owl.caretLookPending), looks \(owl.caretLooks - looks)")
                            next()
                            return
                        }
                        settle(turns + 1)
                    }
                }
                settle(0)
            }
        }
        /// The owl's fade against the caret's place, from laid-out geometry.
        func caretNearOwl() -> Bool? {
            guard let owl = tab.owl, let window = tab.window else { return nil }
            let tv = tab.primaryTextView
            let screen = tv.firstRect(forCharacterRange: NSRange(location: NSMaxRange(tv.selectedRange()), length: 0), actualRange: nil)
            guard screen != .zero else { return false }
            let caret = owl.overlay.convert(window.convertFromScreen(screen), from: nil)
            return caret.insetBy(dx: -28, dy: -18).intersects(owl.owl.frame)
        }
        /// Puts the caret on a laid-out place in the viewport whose rect
        /// touches the owl (from the end of the viewport back).
        func caretByOwl() -> Bool {
            guard let owl = tab.owl, let window = tab.window, let vr = tab.primaryTextView.viewportCharacterRange else { return false }
            let tv = tab.primaryTextView
            var loc = NSMaxRange(vr)
            while loc >= vr.location {
                let screen = tv.firstRect(forCharacterRange: NSRange(location: loc, length: 0), actualRange: nil)
                if screen != .zero, owl.overlay.convert(window.convertFromScreen(screen), from: nil).insetBy(dx: -28, dy: -18).intersects(owl.owl.frame) {
                    tv.setSelectedRange(NSRange(location: loc, length: 0))
                    return true
                }
                loc -= 8
            }
            return false
        }
        run([
            sync {
                tab.window?.makeKeyAndOrderFront(nil)
                tab.window?.makeFirstResponder(tab.textView)
                tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
                timed("Base64 Encode") { tab.applyTextTool(.base64Encode) }
            },
            sync { timed("undo") { key("z", [.command]) } },
            sync { timed("redo") { key("z", [.command, .shift]) } },
            sync {
                expect(tab.textView.contentStorage?.chunkLimit == LargeDocument.chunkLength, "the 7 M-character line is in chunks (large mode)",
                       String(describing: tab.textView.contentStorage?.chunkLimit))
                timed("type") { type("qexcarzrpya") }
            },
            sync { timed("Add Next Occurrence") { tab.textView.addNextOccurrence() } },
            sync {
                timed("split") { tab.toggleSplit() }
                expect(tab.isSplit, "split: the split is open")
                expect(tab.window?.firstResponder is EditorTextView && tab.window?.firstResponder !== tab.primaryTextView,
                       "split: the new pane has the focus")
            },
            sync {
                timed("unsplit") { tab.toggleSplit() }
                expect(!tab.isSplit && tab.window?.firstResponder === tab.primaryTextView, "unsplit: the primary pane has the focus")
                expect(tab.primaryTextView.contentStorage?.chunkLimit != nil, "unsplit: still in chunks")
            },
            typedToOwl("type after unsplit") { type("etydolljwp") },
            typedToOwl("one more key") { key("k") },
            sync {
                mark("checks")
                expect(tab.text.hasSuffix("etydolljwpk"), "the typed text is there", String(tab.text.suffix(16)))
                for name in ["type after unsplit", "one more key"] {
                    let ms = timings.ms[name] ?? .infinity
                    expect(ms < 250, "\(name) takes under 250 ms, the owl's caret look included", String(format: "%.0f ms", ms))
                }
            },
            // The owl keeps out of the caret's way in the chunked line. The
            // caret by the owl (a place in the laid-out viewport whose rect
            // touches it): it fades.
            sync {
                mark("caret by the owl")
                expect(caretByOwl(), "a laid-out place by the owl", String(describing: tab.primaryTextView.viewportCharacterRange))
            },
            sync {
                expect(caretNearOwl() == true && tab.owl?.owlFaded == true, "caret by the owl: it fades",
                       "near \(String(describing: caretNearOwl())), faded \(String(describing: tab.owl?.owlFaded))")
                // A split shrinks the pane away from under the still caret
                // (TextKit may lay out no new viewport for it).
                mark("split resize")
                tab.toggleSplit()
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                let near = caretNearOwl()
                expect(tab.isSplit && near == false, "split resize: the pane shrank away from under the caret", "near \(String(describing: near))")
                expect(tab.owl?.owlFaded == near, "after a split resize the owl's fade follows the caret",
                       "faded \(String(describing: tab.owl?.owlFaded)), caret near \(String(describing: near))")
                mark("unsplit")
                tab.toggleSplit()
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                let near = caretNearOwl()
                expect(tab.owl?.owlFaded == near, "after the unsplit the owl's fade follows the caret",
                       "faded \(String(describing: tab.owl?.owlFaded)), caret near \(String(describing: near))")
                mark("caret by the owl again")
                expect(caretByOwl(), "a laid-out place by the owl, again", String(describing: tab.primaryTextView.viewportCharacterRange))
            },
            sync {
                expect(tab.owl?.owlFaded == true, "caret by the owl again: it fades", "faded \(String(describing: tab.owl?.owlFaded))")
                // Scrolled away from the caret: the owl is back.
                mark("scroll away")
                let clip = tab.primaryPane.scrollView.contentView
                clip.scroll(to: .zero)
                tab.primaryPane.scrollView.reflectScrolledClipView(clip)
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                expect(tab.owl?.owlFaded == false, "scrolled away from the caret: the owl is back", "faded \(String(describing: tab.owl?.owlFaded))")
                // Scrolled back: the scroll is heard before TextKit has laid
                // out the new viewport (the old one, at the top, hasn't the
                // caret). Once it has, the owl fades again.
                mark("scroll back")
                tab.primaryTextView.scrollRangeToVisible(tab.primaryTextView.selectedRange())
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { next() } },
            sync {
                let near = caretNearOwl()
                expect(near == true && tab.owl?.owlFaded == true, "scrolled back to the caret by the owl: it fades once the viewport is laid out",
                       "near \(String(describing: near)), faded \(String(describing: tab.owl?.owlFaded))")
                mark("caret far away")
                tab.primaryTextView.setSelectedRange(NSRange(location: 0, length: 0))
            },
            sync {
                mark("checks")
                expect(tab.owl?.owlFaded == false, "caret out of view: the owl is back", "faded \(String(describing: tab.owl?.owlFaded))")
            },
            // The caret at the viewport's end: the start of the next chunk,
            // not laid out. The owl's look takes the caret's place from what
            // is laid out and lays nothing more out (firstRect laid that
            // chunk out on the main thread: 0.5.4 QA, Codex review). The
            // caret belongs to that next chunk, so it is out of view: the
            // chunk before must not answer for it (Codex review round 2).
            sync {
                mark("scroll to the top")
                let clip = tab.primaryPane.scrollView.contentView
                clip.scroll(to: .zero)
                tab.primaryPane.scrollView.reflectScrolledClipView(clip)
            },
            waitFor("the viewport at the top is laid out") { viewportLaidOutAtTop() },
            sync {
                mark("caret at the viewport's end")
                let tv = tab.primaryTextView
                guard let owl = tab.owl, let vr = tv.viewportCharacterRange, let tlm = tv.textLayoutManager,
                      let tcm = tlm.textContentManager else { expect(false, "a laid-out viewport and the owl"); return }
                let end = NSMaxRange(vr), length = (tab.text as NSString).length
                expect(end < length - 4096, "the viewport ends before the line does", "\(vr) of \(length)")
                tv.setSelectedRange(NSRange(location: end, length: 0))
                let doc = tcm.documentRange.location
                guard let next = tcm.location(doc, offsetBy: end), let after = tcm.location(next, offsetBy: 4096),
                      let unlaid = NSTextRange(location: next, end: after) else {
                    expect(false, "the next chunk's place"); return
                }
                tlm.invalidateLayout(for: unlaid)
                func nextLaidOut() -> Bool {
                    var laid = false
                    tlm.enumerateTextLayoutFragments(from: next, options: []) { frag in
                        laid = frag.state == .layoutAvailable && frag.rangeInElement.location.compare(next) != .orderedDescending
                        return false
                    }
                    return laid
                }
                expect(!nextLaidOut(), "the chunk after the viewport isn't laid out")
                // Still the viewport's end after the invalidation: the caret
                // is at the boundary the look must handle, not simply out of
                // the viewport (where any version says "out of view").
                let endNow = tv.viewportCharacterRange.map(NSMaxRange)
                expect(endNow == end, "the caret is still at the viewport's end", "\(end) → \(String(describing: endNow))")
                expect(tv.laidOutCaretRect(at: end) == nil,
                       "the caret at the viewport's end has no laid-out place (it starts the next chunk)",
                       String(describing: tv.laidOutCaretRect(at: end)))
                expect(tv.laidOutCaretRect(at: vr.location) != nil,
                       "…a caret at the top of the viewport, in view, has one", String(describing: tv.laidOutCaretRect(at: vr.location)))
                expect(!nextLaidOut(), "…and asking laid nothing out past the viewport")
                let looks = owl.caretLooks
                owl.caretMoved()
                expect(owl.caretLooks > looks, "the owl looked at the caret at the viewport's end")
                expect(!nextLaidOut(), "…and laid nothing out past the viewport for it")
            },
            // The same with the viewport's end in view: scrolled so a chunk's
            // bottom is the visible rect's bottom, the viewport ends with that
            // chunk, and its last line is on screen. The caret there starts
            // the next chunk, below: out of view, not at the end of the line
            // above (the chunk before answered for it: Codex review round 2).
            sync {
                mark("a chunk's bottom at the visible bottom")
                let tv = tab.primaryTextView
                guard let tlm = tv.textLayoutManager, let vr = tlm.textViewportLayoutController.viewportRange else {
                    expect(false, "a viewport"); return
                }
                let h = tv.visibleRect.height
                var bottom: CGFloat?
                tlm.enumerateTextLayoutFragments(from: vr.location, options: [.ensuresLayout]) { frag in
                    let maxY = frag.layoutFragmentFrame.maxY + tv.textContainerOrigin.y
                    if maxY > h + 40 { bottom = maxY; return false }
                    return true
                }
                guard let bottom else { expect(false, "a chunk lower than the visible rect"); return }
                viewport.bottom = bottom
                let clip = tab.primaryPane.scrollView.contentView
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: bottom - h))
                tab.primaryPane.scrollView.reflectScrolledClipView(clip)
            },
            waitFor("the viewport there is laid out") { viewportLaidOutAtTop() },
            sync {
                let tv = tab.primaryTextView
                guard let vr = tv.viewportCharacterRange, let tlm = tv.textLayoutManager else { expect(false, "a viewport"); return }
                let end = NSMaxRange(vr)
                var endsAt: CGFloat?
                tlm.enumerateTextLayoutFragments(from: tlm.textViewportLayoutController.viewportRange?.location ?? tlm.documentRange.location, options: []) { frag in
                    if tv.offset(of: frag.rangeInElement.endLocation) == end { endsAt = frag.layoutFragmentFrame.maxY + tv.textContainerOrigin.y; return false }
                    return true
                }
                expect(endsAt == viewport.bottom && abs(tv.visibleRect.maxY - (endsAt ?? 0)) < 0.5,
                       "the viewport ends with the chunk whose bottom is the visible bottom",
                       "ends at \(String(describing: endsAt)), chunk bottom \(String(describing: viewport.bottom)), visible \(tv.visibleRect)")
                expect(tv.laidOutCaretRect(at: end - 1) != nil, "the last character before the viewport's end is in view",
                       String(describing: tv.laidOutCaretRect(at: end - 1)))
                expect(tv.laidOutCaretRect(at: end) == nil, "a caret at the viewport's end, in view or not, starts the next chunk: no place",
                       String(describing: tv.laidOutCaretRect(at: end)))
                let clip = tab.primaryPane.scrollView.contentView
                clip.scroll(to: .zero)
                tab.primaryPane.scrollView.reflectScrolledClipView(clip)
            },
            waitFor("back at the top, laid out") { viewportLaidOutAtTop() && tab.primaryTextView.visibleRect.minY == 0 },
            // A viewport pass that lays out the same characters elsewhere (a
            // small scroll within the chunks laid out) is heard from TextKit
            // itself (NSView.layout() alone missed it), and the owl looks
            // again from it.
            sync {
                mark("small scroll")
                let tv = tab.primaryTextView
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                viewport.range = tv.viewportCharacterRange
                viewport.reported = tv.viewportLayoutsReportedByTextKit
                viewport.rechecks = tab.owl?.layoutRechecks ?? 0
                viewport.looks = tab.owl?.caretLooks ?? 0
                let clip = tab.primaryPane.scrollView.contentView
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + 6))
                tab.primaryPane.scrollView.reflectScrolledClipView(clip)
            },
            waitFor("TextKit reports the small scroll's viewport pass") {
                tab.primaryTextView.viewportLayoutsReportedByTextKit > viewport.reported && viewportLaidOutAtTop()
            },
            waitFor("the owl's look after that pass has run") {
                guard let owl = tab.owl else { return false }
                return owl.layoutRechecks > viewport.rechecks && !owl.caretLookPending
            },
            sync {
                let tv = tab.primaryTextView
                expect(tv.viewportCharacterRange == viewport.range, "a small scroll lays out the same characters",
                       "\(String(describing: viewport.range)) → \(String(describing: tv.viewportCharacterRange))")
                expect(tv.viewportLayoutsReportedByTextKit > viewport.reported, "…and TextKit's word on that pass is heard",
                       "\(tv.viewportLayoutsReportedByTextKit - viewport.reported) passes")
                expect((tab.owl?.layoutRechecks ?? 0) > viewport.rechecks && (tab.owl?.caretLooks ?? 0) > viewport.looks,
                       "…and the owl looked at the caret again from it",
                       "rechecks \((tab.owl?.layoutRechecks ?? 0) - viewport.rechecks), looks \((tab.owl?.caretLooks ?? 0) - viewport.looks)")
                for (k, v) in timings.ms.sorted(by: { $0.key < $1.key }) { print(String(format: "check: note: %@ %.0f ms", k, v)) }
                tab.doc.markSaved()
            },
        ], gap: 0.1)
    }
}
