import AppKit
import CedricCore
import CedricAI

/// CEDRIC_OWL_CHECK_CHAT=1 (with CEDRIC_OWL_CHECK and the fake engine,
/// CEDRIC_AI_FAKE): Ask Cedric end to end, by real key and mouse events.
///
///   1. ⌥⌘/ opens the panel (made on first use);
///   2. Explain: the answer streams in (several partial lengths seen);
///   3. Add Comments on a selected line, with tools: get_lines, then
///      propose_edit becomes a diff; Apply changes the text; one ⌘Z undoes it;
///   4. three proposals at once: a card each, Skip, Apply, read-only;
///   5. Add Comments again, then an edit elsewhere (the card still applies)
///      and one inside the proposed text: Apply refuses, Ask Again shows;
///   6. Stop cancels a running answer;
///   7. Escape closes the panel.
/// Before step 2, the one owl (`owlInChat`): the panel has no owl of its
/// own and opens beside the editor's owl; he waves, listens to real
/// typing, thinks, searches, talks and nods through a question, and only
/// changes still poses under Reduce Motion; his own idle animations wait
/// meanwhile. After step 7 (`placement`): reopened beside him wherever he
/// moved, at the default place with the owl hidden (the chat still
/// works), where the user left it once moved; nothing left running after
/// close.
@MainActor
enum OwlChatCheck {
    static func check(_ ok: Bool, _ what: String) { OwlCheck.check(ok, what) }
    static func after(_ s: Double, _ f: @escaping @MainActor () -> Void) { OwlCheck.after(s, f) }

    static func run(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window else { return }
        check(tab.owlChat == nil, "no chat panel before it is asked for")
        OwlView.reduceMotion = false
        tab.owl?.reduceMotionChanged()
        OwlCheck.key(window, "/", code: 44, [.command, .option])
        after(0.3) {
            guard let chat = tab.owlChat, chat.isShown else {
                check(false, "⌥⌘/ opens Ask Cedric"); OwlCheck.finish(out); return
            }
            check(true, "⌥⌘/ opens Ask Cedric")
            owlInChat(tab, chat, out: out) { explain(tab, chat, out: out) }
        }
    }

    /// CEDRIC_OWL_CHECK_CHAT_OFF=1, no CEDRIC_OWL_CHAT, a fresh defaults
    /// domain and no engine ready (CEDRIC_ASK_ENGINE=0): Ask Cedric is off,
    /// Ask Cedric and Check Grammar with Cedric are disabled, ⌥⌘/ opens
    /// nothing, and the owl offers Set Up Ask Cedric… first.
    static func runDefaultOff(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window, let app = NSApp.delegate as? AppDelegate else { OwlCheck.finish(out); return }
        check(DevEnvironment.values["CEDRIC_OWL_CHAT"] == nil, "no CEDRIC_OWL_CHAT override")
        check(UserDefaults.standard.object(forKey: "owlChat") == nil, "fresh defaults: owlChat was never set")
        check(!AskCedricEngine.isAvailable, "no engine ready (CEDRIC_ASK_ENGINE=0)")
        check(!Settings.shared.owlChat, "Ask Cedric is off with no engine ready")
        check(!tab.canAskCedric, "the tab can't Ask Cedric")
        if let ask = menuItem(#selector(AppDelegate.askCedricMenu(_:))) {
            check(!app.validateMenuItem(ask), "Cedric › Ask Cedric… is disabled")
        } else { check(false, "Cedric › Ask Cedric… is in the menu") }
        if let grammar = menuItem(#selector(AppDelegate.checkGrammarWithAIMenu(_:))) {
            check(!app.validateMenuItem(grammar), "Check Grammar with Cedric is disabled")
        } else { check(false, "Check Grammar with Cedric is in the menu") }
        OwlCheck.key(window, "/", code: 44, [.command, .option])
        after(0.4) {
            check(tab.owlChat == nil, "⌥⌘/ opens no chat panel")
            guard let owl = tab.owl else { OwlCheck.finish(out); return }
            OwlCheck.click(owl.owl)
            after(0.3) {
                check(owl.popoverButton(String(localized: "Set Up Ask Cedric…")) != nil, "the owl offers Set Up Ask Cedric…")
                check(owl.popoverButtonsFit, "every button in the owl's popover fits inside it")
                check(owl.popoverButton(String(localized: "Ask about this file…")) == nil, "and no Ask about this file…")
                guard let pw = owl.popoverButton(String(localized: "Set Up Ask Cedric…"))?.window else { owl.closePopover(); OwlCheck.finish(out); return }
                OwlCheck.snapshot(pw, "\(out)/owl-menu-setup.png") {
                    owl.closePopover()
                    OwlCheck.finish(out)
                }
            }
        }
    }

    static func menuItem(_ action: Selector) -> NSMenuItem? {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for i in menu?.items ?? [] {
                if i.action == action { return i }
                if let found = find(i.submenu) { return found }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    /// CEDRIC_OWL_CHECK_CHAT=default, fresh defaults, no CEDRIC_OWL_CHAT,
    /// an engine ready (the fake): Ask Cedric is on by default; the owl's
    /// first item is Ask about this file…, which opens the panel; and the
    /// one-time hint (CEDRIC_ASK_HINT=1) shows once and is remembered.
    static func runDefaultOn(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window, let owl = tab.owl else { OwlCheck.finish(out); return }
        check(UserDefaults.standard.object(forKey: "owlChat") == nil, "fresh defaults: owlChat was never set")
        check(AskCedricEngine.isAvailable, "an engine is ready (the fake)")
        check(Settings.shared.owlChat, "Ask Cedric is on by default when an engine is ready")
        UserDefaults.standard.removeObject(forKey: OwlController.askIntroKey)
        // The one-time hint.
        after(0.8) {
            owl.introduceAskCedric()   // what the idle tick does
            let b = owl.bubble
            check(b?.hint.id == OwlController.askIntroID, "the owl introduces Ask Cedric once (\(b?.hint.title ?? "no bubble"))")
            check(UserDefaults.standard.bool(forKey: OwlController.askIntroKey), "and remembers that it did")
            OwlCheck.snapshot(window, "\(out)/ask-intro.png") {
                if let got = b?.buttons.first(where: { $0.title == String(localized: "Got it") }) { OwlCheck.click(got) }
                check(owl.bubble == nil, "Got it closes it")
                check(!owl.introduceAskCedric() && owl.bubble == nil, "it doesn't come back")
                OwlCheck.click(owl.owl)
                after(0.3) {
                    guard let first = owl.popoverButton(String(localized: "Ask about this file…")) else {
                        check(false, "the owl offers Ask about this file…"); OwlCheck.finish(out); return
                    }
                    let stack = first.superview as? NSStackView
                    check(stack?.arrangedSubviews.first === first, "Ask about this file… is the first item")
                    check(owl.popoverButton(String(localized: "Set Up Ask Cedric…")) == nil, "no Set Up item with an engine ready")
                    check(owl.popoverButton(String(localized: "Check Script for Risks…")) == nil, "no script check for a Swift file")
                    OwlCheck.snapshot(first.window ?? window, "\(out)/owl-menu.png") {
                        OwlCheck.click(first)
                        after(0.3) {
                            check(tab.owlChat?.isShown == true, "Ask about this file… opens Ask Cedric")
                            if let chat = tab.owlChat {
                                check(chat.actionButtons[.explainLine]?.isHidden == false, "Explain Line is offered for code")
                                check(chat.actionButtons[.scriptSafety]?.isHidden == true, "Check for Risks isn't, for Swift")
                                check(chat.actionButtons[.summarise]?.isHidden == true, "Summarise isn't, for code")
                                explainLine(tab, chat, out: out)
                            } else { OwlCheck.finish(out) }
                        }
                    }
                }
            }
        }
    }

    /// Explain Line with only a caret: the caret's line is what is asked about.
    static func explainLine(_ tab: EditorWindowController, _ chat: OwlChatPanel, out: String) {
        let ns = tab.text as NSString
        let line3 = ns.lineRange(for: NSRange(location: ns.range(of: "for ").location, length: 0))
        tab.textView.setSelectedRange(NSRange(location: line3.location + 2, length: 0))
        chat.refresh()
        OwlCheck.click(chat.actionButtons[.explainLine]!)
        waitDone(chat) { _ in
            check(chat.transcriptText.contains("Lines 3–3 look fine"), "Explain Line asked about the caret's line only (line 3)")
            check(tab.textView.selectedRange().length == 0, "the caret is left alone")
            chat.close()
            OwlCheck.finish(out)
        }
    }

    /// CEDRIC_OWL_CHECK_CHAT=script: a risky PowerShell script. The owl
    /// offers the check; the offline scan's findings show first; then the
    /// (fake) model's review with a verdict. CEDRIC_OWL_CHAT=0 too: the
    /// scan alone, with a note that no AI was asked.
    static func runScript(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window, let owl = tab.owl else { OwlCheck.finish(out); return }
        let aiOn = Settings.shared.owlChat
        OwlCheck.click(owl.owl)
        after(0.3) {
            guard let b = owl.popoverButton(String(localized: "Check Script for Risks…")) else {
                check(false, "the owl offers Check Script for Risks… for a .ps1"); OwlCheck.finish(out); return
            }
            check(true, "the owl offers Check Script for Risks… for a .ps1")
            OwlCheck.snapshot(b.window ?? window, "\(out)/owl-menu-script.png") { OwlCheck.click(b) }
            after(0.2) {
                guard let chat = tab.owlChat, chat.isShown else { check(false, "the check opens the panel"); OwlCheck.finish(out); return }
                waitDone(chat, timeout: 20) { _ in
                    after(0.3) {
                        let scan = chat.lastScan ?? []
                        let cats = Set(scan.map(\.category))
                        check(cats.isSuperset(of: [.downloadAndRun, .encoded, .disablesSecurity, .broadDelete]),
                              "the offline scan flagged download-and-run, encoded, security off and a broad delete (\(scan.count) findings)")
                        check(chat.transcriptText.contains("Offline scan (no AI)"), "the scan's findings are in the transcript")
                        check(chat.transcriptText.contains("Verdict: " + ScriptVerdict.forcedDontRun),
                              "a high finding forces the verdict \"\(ScriptVerdict.forcedDontRun)\"")
                        check(chat.transcriptText.range(of: "safe to run", options: .caseInsensitive) == nil,
                              "the transcript never says \"safe to run\"")
                        if aiOn {
                            check(chat.transcriptText.contains("Verdict:"), "the model's review ends with a verdict")
                            let renders = chat.streamedRenders
                            check(!renders.isEmpty && renders.allSatisfy { r in
                                r.range(of: "safe to run", options: .caseInsensitive) == nil && r.hasSuffix("Verdict: " + ScriptVerdict.forcedDontRun + ".")
                                    && !r.contains(ScriptVerdict.trustSource)
                            }, "every streamed render is clamped: the forced verdict only, never the model's (\(renders.count) renders)")
                            if DevEnvironment.values["CEDRIC_AI_FAKE"] != nil {
                                check(chat.transcriptText.contains("Line \(scan.first?.line ?? 0): risky"), "the model was given the scan's findings")
                            } else {
                                print("owlcheck: live answer: \(chat.transcriptText.components(separatedBy: "Cedric\n").last ?? "")")
                            }
                        } else {
                            check(chat.transcriptText.contains("offline scan only"), "with Ask Cedric off, the scan alone, saying so")
                            check(chat.asks == 0, "and no AI request")
                        }
                        OwlCheck.snapshot(chat.panel, "\(out)/script-safety\(aiOn ? "" : "-offline").png") {
                            chat.close()
                            _ = window
                            OwlCheck.finish(out)
                        }
                    }
                }
            }
        }
    }

    /// Types `text` into the question field, key by key, through the panel.
    static func type(_ chat: OwlChatPanel, _ text: String) {
        chat.panel.makeKeyAndOrderFront(nil)
        chat.panel.makeFirstResponder(chat.input)
        for ch in text { OwlCheck.key(chat.panel, String(ch), code: 0, []) }
    }

    /// An owl view anywhere in the panel (there must be none).
    static func hasOwlView(_ v: NSView?) -> Bool {
        guard let v else { return false }
        if v is OwlView || v.accessibilityLabel() == String(localized: "Cedric the owl") { return true }
        return v.subviews.contains { hasOwlView($0) }
    }

    /// The panel beside the owl: `gap` from him on one side, overlapping
    /// him along the other axis, inside the screen's visible frame, at the
    /// origin `OwlChatPlacement` gives.
    static func checkBeside(_ tab: EditorWindowController, _ chat: OwlChatPanel, _ what: String) {
        guard let owl = tab.owl?.screenFrame else { check(false, "\(what): the owl is on screen"); return }
        let p = chat.panel.frame
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: owl.midX, y: owl.midY)) }?.visibleFrame ?? .zero
        let want = OwlChatPlacement.panelOrigin(owl: owl, panel: p.size, screen: screen)
        let gap = OwlChatPlacement.gap
        let side = (abs(p.minX - (owl.maxX + gap)) < 0.5 || abs(owl.minX - (p.maxX + gap)) < 0.5) && p.minY < owl.maxY && p.maxY > owl.minY
        let stacked = (abs(p.minY - (owl.maxY + gap)) < 0.5 || abs(owl.minY - (p.maxY + gap)) < 0.5) && p.minX < owl.maxX && p.maxX > owl.minX
        check(chat.openedBesideOwl != nil && hypot(p.minX - want.x, p.minY - want.y) < 0.5 && (side || stacked)
              && !p.intersects(owl) && screen.contains(p),
              "\(what): the panel opens beside the owl (panel \(Int(p.minX)),\(Int(p.minY)) \(Int(p.width))×\(Int(p.height)), owl \(Int(owl.minX)),\(Int(owl.minY)), \(side ? "beside" : stacked ? "above/below" : "apart"))")
    }

    /// The one owl: the editor's, reacting to the chat through one
    /// question, then under Reduce Motion.
    static func owlInChat(_ tab: EditorWindowController, _ chat: OwlChatPanel, out: String, then: @escaping @MainActor () -> Void) {
        guard let o = tab.owl, let window = tab.window else { check(false, "the tab has its owl"); OwlCheck.finish(out); return }
        let v = o.owl
        check(chat.scopePopup.accessibilityLabel() == String(localized: "Asking about")
              && chat.input.accessibilityLabel() == String(localized: "Question for Cedric"),
              "Ask Cedric's scope pop-up and input have VoiceOver labels")
        check(!hasOwlView(chat.panel.contentView), "the panel has no owl of its own")
        // 0.2.1: the panel is a floating panel of its own, not a child window.
        check(chat.panel.parent == nil && chat.panel.isFloatingPanel && window.childWindows?.contains(chat.panel) != true,
              "the panel floats on its own, not as a child of the editor window")
        checkBeside(tab, chat, "first open")
        check(o.chatOpen, "the owl knows the panel is open")
        check(o.chatMoodLog.first == .wave, "the editor's owl waves when the panel opens (\(o.chatMoodLog))")
        check(v.isPlaying && o.chatBusy, "the wave plays on him, and the chat holds him while it does")
        OwlCheck.snapshot(window, "\(out)/chat-owl-0-wave.png") {
          OwlCheck.snapshot(chat.panel, "\(out)/chat-panel-0-no-owl.png") {
            after(1.2) {
                check(o.chatMood == .idle && !o.chatBusy && !o.chatGesturePlaying, "the wave settles: he is his own owl again (\(o.chatMood))")
                let before = o.chatMoodLog.count
                type(chat, "Where is 'total' used?")
                let listens = o.chatMoodLog[before...].filter { $0 == .listen }.count
                check(chat.input.stringValue == "Where is 'total' used?", "typed with real keys (\(chat.input.stringValue))")
                check(o.chatMood == .listen && listens == 1, "typing: he listens, once for a burst of keys (\(listens))")
                let look = OwlArt.strip(.look)
                check(v.isPlaying && look.contains { $0 === v.current }, "the listening glance plays on the editor's owl")
                // No double animation: his idle tick and the save flap wait.
                o.idleTickNow()
                o.noteSave()
                check(o.chatBusy && look.contains { $0 === v.current }, "his idle animation and the save flap don't cut into the chat's glance")
                OwlCheck.snapshot(window, "\(out)/chat-owl-1-listen.png") {
                    let start = o.chatMoodLog.count
                    var shots: Set<OwlChatMood> = []
                    var heldWhileWorking = true
                    OwlCheck.key(chat.panel, "\r", code: 36, [])
                    check(chat.running, "Return asks the question")
                    @MainActor func poll() {
                        if chat.running {
                            if o.chatMood.isWorking, !o.chatBusy { heldWhileWorking = false }
                            for m in [OwlChatMood.think, .talk] where o.chatMood == m && !shots.contains(m) {
                                shots.insert(m)
                                OwlCheck.snapshot(window, "\(out)/chat-owl-2-\(m.rawValue).png") {}
                            }
                            after(0.02) { poll() }
                            return
                        }
                        let seen = Array(o.chatMoodLog[start...])
                        let order: [OwlChatMood] = [.think, .search, .talk, .nod]
                        var i = 0
                        for m in seen where i < order.count && m == order[i] { i += 1 }
                        check(i == order.count, "asking: the editor's owl thinks, searches, talks, then nods (\(seen))")
                        check(heldWhileWorking, "the chat holds him the whole time the model works")
                        check(o.chatMood == .nod && v.isPlaying, "the nod plays on him")
                        check(chat.transcriptText.contains("fake answer"), "the answer arrived")
                        OwlCheck.snapshot(window, "\(out)/chat-owl-3-nod.png") {
                            reduced(tab, chat, out: out, then: then)
                        }
                    }
                    after(0.02) { poll() }
                }
            }
          }
        }
    }

    /// Reduce Motion: still poses only, never a strip.
    static func reduced(_ tab: EditorWindowController, _ chat: OwlChatPanel, out: String, then: @escaping @MainActor () -> Void) {
        guard let o = tab.owl, let window = tab.window else { then(); return }
        let v = o.owl
        OwlView.reduceMotion = true
        o.reduceMotionChanged()
        check(!v.isPlaying, "Reduce Motion: nothing plays when idle")
        type(chat, "Explain this")
        check(!v.isPlaying, "Reduce Motion: no listening glance")
        let start = o.chatMoodLog.count
        var moved = false
        var drawn: Set<ObjectIdentifier> = []
        OwlCheck.key(chat.panel, "\r", code: 36, [])
        @MainActor func poll() {
            if v.isPlaying || v.inState { moved = true }
            if let c = v.current { drawn.insert(ObjectIdentifier(c)) }
            if chat.running { after(0.02) { poll() }; return }
            if v.isPlaying || v.inState { moved = true }
            let seen = Array(o.chatMoodLog[start...])
            check(!moved, "Reduce Motion: no strip plays on him while asking (\(seen))")
            check(seen.contains(.think) && seen.contains(.talk), "Reduce Motion: his poses still follow the chat (\(seen))")
            let stills = Set([OwlArt.Pose.idle, .thinking, .talking, .sleepy].compactMap { OwlArt.poses[$0].map(ObjectIdentifier.init) })
            check(drawn.isSubset(of: stills), "Reduce Motion: only still poses are drawn (\(drawn.count) different)")
            OwlCheck.snapshot(window, "\(out)/chat-owl-5-reduce-motion.png") {
                OwlView.reduceMotion = false
                o.reduceMotionChanged()
                chat.clearHistory(nil)
                then()
            }
        }
        after(0.02) { poll() }
    }

    /// Waits until the panel is idle, sampling the streamed length.
    static func waitDone(_ chat: OwlChatPanel, timeout: Double = 15, samples: Set<Int> = [], _ then: @escaping @MainActor (Set<Int>) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        var seen = samples
        func poll() {
            if chat.running {
                seen.insert(chat.streamedCount)
                if Date() > deadline { check(false, "answer finished within \(Int(timeout)) s"); then(seen); return }
                after(0.02) { poll() }
            } else { then(seen) }
        }
        after(0.02) { poll() }
    }

    static func explain(_ tab: EditorWindowController, _ chat: OwlChatPanel, out: String) {
        guard let b = chat.actionButtons[.explain] else { return }
        OwlCheck.click(b)
        check(chat.running || chat.asks == 1, "Explain starts a request")
        waitDone(chat) { seen in
            check(chat.flushes >= 3, "the answer streamed into the transcript in \(chat.flushes) steps (seen while polling: \(seen.filter { $0 > 0 }.count))")
            check(chat.transcriptText.contains("fake answer from the test engine"), "the full answer is in the transcript")
            OwlCheck.snapshot(chat.panel, "\(out)/chat-1-explain.png") { addComments(tab, chat, out: out) }
        }
    }

    static func addComments(_ tab: EditorWindowController, _ chat: OwlChatPanel, out: String) {
        let tv = tab.textView
        let original = tab.text
        let line2 = (original as NSString).lineRange(for: NSRange(location: (original as NSString).range(of: "\n").location + 1, length: 0))
        tv.setSelectedRange(NSRange(location: line2.location, length: line2.length - 1))
        chat.refresh()
        chat.selectScope(.selection)
        guard let b = chat.actionButtons[.addComments] else { return }
        OwlCheck.click(b)
        waitDone(chat) { _ in
            let o = chat.lastOutcome
            check(chat.lastUsedTools, "tools on for the fake engine (CEDRIC_OWL_TOOLS=1)")
            check((o?.toolCalls ?? 0) >= 2, "the model used tools (\(o?.toolCalls ?? 0) calls: get_lines, propose_edit)")
            check(chat.transcriptText.contains("Looked at lines"), "the transcript shows what Cedric looked at")
            check(o?.proposal?.anchor == .text && chat.cards.count == 1 && !chat.cardsScroll.isHidden, "propose_edit (find/replace) became a diff card")
            check(chat.isProposalCurrent && chat.cards.first?.applyButton.isEnabled == true, "Apply is enabled while the text is unchanged")
            check(chat.cards.first?.accessibilityLabel()?.isEmpty == false && chat.cards.first?.diffView.accessibilityValue() as? String != nil,
                  "the card has VoiceOver labels")
            OwlCheck.snapshot(chat.panel, "\(out)/chat-2-diff.png") {
                guard let apply = chat.cards.first?.applyButton else { several(tab, chat, out: out); return }
                OwlCheck.click(apply)
                let applied = tab.text
                check(applied.contains("// \(FakeChatEngine.commentText)\n"), "Apply inserted the comment")
                check(chat.cards.isEmpty && chat.cardsScroll.isHidden, "the card closes after Apply")
                check(tab.owl?.chatMood == .flap && tab.owl?.owl.isPlaying == true,
                      "the editor's owl flaps on Apply (\(tab.owl.map { "\($0.chatMood)" } ?? "no owl"))")
                guard let w = tab.window else { several(tab, chat, out: out); return }
                OwlCheck.snapshot(w, "\(out)/chat-owl-6-flap.png") {
                    w.makeKeyAndOrderFront(nil)
                    w.makeFirstResponder(tv)
                    OwlCheck.key(w, "z", code: 6, [.command])
                    check(tab.text == original, "one ⌘Z undoes Cedric’s edit")
                    several(tab, chat, out: out)
                }
            }
        }
    }

    static func stale(_ tab: EditorWindowController, _ chat: OwlChatPanel, out: String) {
        let tv = tab.textView
        let original = tab.text
        let ns = original as NSString
        let line2 = ns.lineRange(for: NSRange(location: ns.range(of: "\n").location + 1, length: 0))
        tv.setSelectedRange(NSRange(location: line2.location, length: line2.length - 1))
        chat.refresh()
        chat.selectScope(.selection)
        OwlCheck.click(chat.actionButtons[.addComments]!)
        waitDone(chat) { _ in
            check(chat.pending != nil, "a second proposal")
            // The user edits the document meanwhile: first elsewhere (line 1).
            guard let w = tab.window, let p = chat.pending else { return }
            w.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            OwlCheck.key(w, "x", code: 7, [])
            after(0.3) {
                check(chat.isProposalCurrent && chat.cards.first?.applyButton.isEnabled == true,
                      "an edit elsewhere leaves the find/replace card applicable")
                // Then inside the text it would replace.
                let at = (tab.text as NSString).range(of: p.original)
                tv.setSelectedRange(NSRange(location: at.location + 1, length: 0))
                OwlCheck.key(w, "x", code: 7, [])
                after(0.3) {
                    check(!chat.isProposalCurrent, "after an edit inside it the proposal is stale")
                    check(chat.cards.first?.applyButton.isEnabled == false, "Apply is disabled once stale")
                    let before = tab.text
                    let ok = chat.applyProposal(nil)
                    check(!ok && tab.text == before, "Apply refuses a stale proposal")
                    check(chat.cards.first?.askAgainButton.isHidden == false && chat.cards.first?.staleLabel.stringValue == OwlEditCard.staleText,
                          "the card says it changed and offers Ask Again")
                    OwlCheck.snapshot(chat.panel, "\(out)/chat-3-stale.png") {
                        chat.discardProposal(nil)
                        cancel(tab, chat, out: out)
                    }
                }
            }
        }
    }

    /// Three proposals at once (as a model's three propose_edit calls make
    /// them): a card each; Skip one, Apply another (the third, elsewhere,
    /// still applies); read-only, none applies; one ⌘Z undoes the edit.
    static func several(_ tab: EditorWindowController, _ chat: OwlChatPanel, out: String) {
        let previousSelection = tab.textView.selectedRange()
        let selected = "for i in items"
        let selection = (tab.text as NSString).range(of: selected)
        if selection.location != NSNotFound {
            tab.textView.setSelectedRange(selection)
            let before = tab.text
            let selectedSnapshot = chat.snapshot()
            if let proposal = try? OwlEditProposal.anchored(find: selected, replace: "for item in items", in: selectedSnapshot).get() {
                chat.showProposals([proposal])
                if let card = chat.cards.first {
                    chat.skip(card)
                    check(chat.cards.isEmpty && tab.text == before, "Skip of an anchored selection changes nothing")
                } else { check(false, "selection proposal has a card") }
            } else { check(false, "selection anchors a proposal") }
        } else { check(false, "selection for the card check exists") }
        tab.textView.setSelectedRange(previousSelection)
        let snap = chat.snapshot()
        let edits = [("for i in items", "for item in items", "clearer name"), ("return t", "return t // sum", "says what it returns"),
                     ("-> Int {", "-> Int { // total", "says what it is")]
        let ps = edits.compactMap { try? OwlEditProposal.anchored(find: $0.0, replace: $0.1, reason: $0.2, in: snap).get() }
        guard ps.count == 3, let w = tab.window else { check(false, "three proposals for the cards check"); stale(tab, chat, out: out); return }
        chat.showProposals(ps)
        check(chat.cards.count == 3 && chat.cards.allSatisfy(\.isReady), "three proposals: three cards, each applicable")
        check(chat.cards[0].titleLabel.stringValue.contains("1") && chat.cards[0].titleLabel.stringValue.contains("3"), "cards are numbered (\(chat.cards[0].titleLabel.stringValue))")
        check(chat.cards[1].accessibilityLabel()?.contains("says what it returns") == true
              && chat.cards[1].applyButton.accessibilityLabel()?.contains("line") == true, "VoiceOver hears each card's reason and what Apply changes")
        OwlCheck.snapshot(chat.panel, "\(out)/chat-4-cards.png") {
            let before = tab.text
            OwlCheck.click(chat.cards[0].skipButton)
            check(chat.cards.count == 2 && tab.text == before, "Skip drops a card and changes nothing")
            OwlCheck.click(chat.cards[0].applyButton)
            let applied = tab.text
            check(applied.contains("return t // sum") && !applied.contains("for item in items"), "Apply changes only its own text")
            check(chat.cards.count == 1 && chat.cards[0].isReady, "the card left still applies after an edit elsewhere")
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(tab.textView)
            // The window becomes key first, so ⌘Z goes to the text, not the panel's field.
            after(0.3) {
                OwlCheck.key(w, "z", code: 6, [.command])
                check(tab.text == before, "one ⌘Z undoes the applied card")
                tab.textView.isEditable = false
                chat.refreshCards()
                check(chat.cards.first?.state == .readOnly && chat.cards.first?.applyButton.isEnabled == false
                      && chat.cards.first?.staleLabel.stringValue == OwlEditCard.readOnlyText, "read-only: Apply is off and the card says why")
                check(!chat.applyProposal(nil) && tab.text == before, "read-only: nothing applies")
                OwlCheck.snapshot(chat.panel, "\(out)/chat-5-readonly.png") {
                    tab.textView.isEditable = true
                    chat.discardProposal(nil)
                    stale(tab, chat, out: out)
                }
            }
        }
    }

    static func cancel(_ tab: EditorWindowController, _ chat: OwlChatPanel, out: String) {
        tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
        chat.refresh()
        OwlCheck.click(chat.actionButtons[.explain]!)
        after(0.15) {
            check(chat.running, "a request is running")
            OwlCheck.click(chat.stopButton)
            after(0.1) {
                check(!chat.running, "Stop cancels it")
                check(chat.transcriptText.contains("Stopped"), "the transcript says it stopped")
                check(chat.stopButton.isHidden && !chat.sendButton.isHidden, "Ask is back after Stop")
                let count = chat.streamedCount
                after(0.4) {
                    check(chat.streamedCount == count, "nothing more arrives after Stop")
                    let md = { () -> String in chat.copyMarkdown(nil); return NSPasteboard.general.string(forType: .string) ?? "" }()
                    check(md.contains("**You:**") && md.contains("```diff"), "Copy as Markdown has the questions and the diff")
                    finishChecks(tab, chat, out: out)
                }
            }
        }
    }

    static func finishChecks(_ tab: EditorWindowController, _ chat: OwlChatPanel, out: String) {
        chat.panel.makeKeyAndOrderFront(nil)
        chat.panel.makeFirstResponder(chat.input)
        if let fe = chat.panel.fieldEditor(false, for: chat.input) {
            _ = chat.control(chat.input, textView: fe as! NSTextView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        }
        after(0.3) {
            check(!chat.isShown, "Escape closes the panel")
            checkClosed(tab, chat, "after Escape")
            placement(tab, chat, out: out)
        }
    }

    /// Closed: the chat holds nothing: no panel timer or task, the owl his
    /// own (no chat mood, no chat gesture or loop on him).
    static func checkClosed(_ tab: EditorWindowController, _ chat: OwlChatPanel, _ what: String) {
        let o = tab.owl
        let mood = o?.chatMood ?? .idle
        let held = o.map { $0.chatBusy || $0.chatGesturePlaying || $0.owl.inState } ?? false
        check(!chat.hasTimers && mood == .idle && !held && o?.chatOpen != true,
              "\(what): no timers or animation left from the chat (panel timers \(chat.hasTimers), mood \(mood), owl held \(held))")
        check(!chat.followsTabWindow, "\(what): the panel no longer watches the tab's window")
    }

    static func reopen(_ tab: EditorWindowController, _ then: @escaping @MainActor (OwlChatPanel) -> Void) {
        guard let w = tab.window else { return }
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(tab.textView)
        OwlCheck.key(w, "/", code: 44, [.command, .option])
        after(0.3) {
            guard let chat = tab.owlChat, chat.isShown else { check(false, "⌥⌘/ reopens Ask Cedric"); OwlCheck.finish(""); return }
            then(chat)
        }
    }

    static func setOwlShown(_ on: Bool) {
        Settings.shared.owlOverride = on
        NotificationCenter.default.post(name: .cedricOwlSettingsChanged, object: nil)
    }

    /// Where it reopens: beside the owl wherever he moved; with the owl
    /// hidden, at the default place (and the chat still works); once the
    /// user moved it, where they left it.
    static func placement(_ tab: EditorWindowController, _ first: OwlChatPanel, out: String) {
        guard let o = tab.owl, let w = tab.window else { check(false, "the owl is back"); OwlCheck.finish(out); return }
        let firstFrame = first.panel.frame
        o.moveTo(OwlPlacement(corner: .topLeft, inset: OwlPlacement.margin))
        after(0.4) {
            reopen(tab) { chat in
                checkBeside(tab, chat, "the owl moved to the top left")
                check(chat.panel.frame.origin != firstFrame.origin, "so it opens somewhere else than the first time")
                OwlCheck.snapshot(w, "\(out)/chat-owl-7-moved.png") {
                    chat.close()
                    split(tab, out: out) { hideOwl(tab, out: out) }
                }
            }
        }
    }

    /// 0.3.0, split side by side: the owl lives in the first pane; at his
    /// default bottom right he is in the middle of the window, and the
    /// panel opens beside him there, not beside the window's corner.
    static func split(_ tab: EditorWindowController, out: String, then: @escaping @MainActor () -> Void) {
        guard let w = tab.window else { then(); return }
        tab.splitPanes(sideBySide: true, ratio: 0.5, focusSecond: true)
        tab.owl?.resetPosition()
        after(0.4) {
            reopen(tab) { chat in
                let pane = tab.primaryPane.container
                let paneRect = w.convertToScreen(pane.convert(pane.bounds, to: nil))
                let owl = tab.owl?.screenFrame ?? .zero
                check(tab.isSplit && paneRect.contains(owl) && owl.maxX < w.frame.midX + 4,
                      "split side by side: the owl sits in the first pane, at its bottom right (owl \(Int(owl.minX)),\(Int(owl.minY)), pane \(Int(paneRect.minX))–\(Int(paneRect.maxX)))")
                checkBeside(tab, chat, "split side by side")
                OwlCheck.snapshot(w, "\(out)/chat-owl-7b-split.png") {
                    chat.close()
                    tab.unsplit()
                    tab.owl?.moveTo(OwlPlacement(corner: .topLeft, inset: OwlPlacement.margin))
                    after(0.4) { then() }
                }
            }
        }
    }

    /// Hide Cedric: the panel opens at the default place and the chat works.
    static func hideOwl(_ tab: EditorWindowController, out: String) {
        guard let w = tab.window else { OwlCheck.finish(out); return }
        setOwlShown(false)
        check(tab.owl == nil, "Hide Cedric: no owl")
        reopen(tab) { chat in
            check(tab.owl == nil, "opening the panel doesn't bring him back")
            let p = chat.panel.frame
            let screen = (w.screen ?? NSScreen.main)?.visibleFrame ?? w.frame
            let x = min(max(w.frame.maxX - p.width - 24, screen.minX + 4), screen.maxX - p.width - 4)
            let y = min(max(w.frame.minY + 100, screen.minY + 4), screen.maxY - p.height - 4)
            check(chat.openedBesideOwl == nil && abs(p.minX - x) < 0.5 && abs(p.minY - y) < 0.5,
                  "with no owl it opens at the default place, the window's bottom-right corner")
            OwlCheck.click(chat.actionButtons[.explain]!)
            waitDone(chat) { _ in
                check(chat.transcriptText.contains("fake answer"), "the chat works without the owl")
                OwlCheck.snapshot(chat.panel, "\(out)/chat-panel-1-no-owl-shown.png") {
                    chat.clearHistory(nil)
                    chat.close()
                    setOwlShown(true)
                    // Once he is laid out in his new overlay.
                    after(0.3) {
                        tab.owl?.resetPosition()
                        dragged(tab, out: out)
                    }
                }
            }
        }
    }

    /// Moved by the user: reopening keeps their place, wherever the owl is.
    static func dragged(_ tab: EditorWindowController, out: String) {
        guard tab.owl != nil else { check(false, "Show Cedric brings him back"); OwlCheck.finish(out); return }
        after(0.4) {
            if let o = tab.owl {
                let b = o.overlay.bounds, f = o.owl.frame
                check(f.maxX > b.midX && f.minY < b.midY, "Show Cedric and Reset Position: he is back at the bottom right (\(Int(f.minX)),\(Int(f.minY)))")
            }
            reopen(tab) { chat in
                checkBeside(tab, chat, "the owl back at the bottom right")
                check(!chat.movedByUser, "not moved by the user yet")
                // What a title-bar drag ends with (a real drag can't be
                // posted in process: the window server moves the window).
                let f = chat.panel.frame
                let to = NSPoint(x: f.minX - 40, y: f.minY + 30)
                chat.panel.setFrameOrigin(to)
                after(0.1) {
                    check(chat.movedByUser, "moving the panel counts as the user's place")
                    check(chat.panel.parent == nil && chat.panel.isFloatingPanel, "still a free-floating panel after moving")
                    chat.close()
                    tab.owl?.moveTo(OwlPlacement(corner: .topLeft, inset: OwlPlacement.margin))
                    after(0.4) {
                        reopen(tab) { chat in
                            check(chat.openedBesideOwl == nil && chat.panel.frame.origin == to,
                                  "reopened where the user left it, not beside the owl")
                            chat.close()
                            checkClosed(tab, chat, "closed again")
                            tab.owl?.resetPosition()
                            OwlChatCheck.after(0.3) { extra(tab, out) }
                        }
                    }
                }
            }
        }
    }

    /// CEDRIC_OWL_CHECK_CHAT=grammar: Check Grammar with Cedric on a prose file
    /// (the fake engine "finds" "then I expected"): an underline, the
    /// owl's grammar bubble, Fix it, one ⌘Z.
    static func runGrammar(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window else { return }
        let deadline = Date().addingTimeInterval(15)
        func waitProse() {
            if tab.grammar.lastSawProse == true {
                check(tab.canCheckGrammarWithAI, "Check Grammar with Cedric is available in prose")
                let original = tab.text
                NSApp.sendAction(#selector(AppDelegate.checkGrammarWithAIMenu(_:)), to: nil, from: nil)
                check(tab.grammar.aiPasses == 1, "the menu item starts one AI pass")
                waitBubble(original)
                return
            }
            if Date() > deadline { check(false, "the text was found to be prose"); OwlCheck.finish(out); return }
            after(0.2) { waitProse() }
        }
        func waitBubble(_ original: String) {
            if let b = tab.owl?.bubble, GrammarMap.isGrammarHint(b.hint.id) {
                check(b.hint.replacement == "than I expected", "the owl offers the AI's grammar fix (\(b.hint.title))")
                let r = (tab.text as NSString).range(of: "then I expected")
                check(tab.textView.grammarRanges.contains(r), "the AI's finding is underlined like the system's")
                OwlCheck.snapshot(window, "\(out)/grammar-ai.png") {
                    guard let fix = b.buttons.first(where: { $0.title == String(localized: "Fix it") }) else { check(false, "Fix it"); OwlCheck.finish(out); return }
                    OwlCheck.click(fix)
                    check(tab.text.contains("than I expected") && !tab.text.contains("then I expected"), "Fix it applied the AI's correction")
                    window.makeFirstResponder(tab.textView)
                    OwlCheck.key(window, "z", code: 6, [.command])
                    check(tab.text == original, "one ⌘Z undoes it")
                    OwlCheck.finish(out)
                }
                return
            }
            if Date() > deadline { check(false, "a grammar bubble from the AI within 15 s"); OwlCheck.finish(out); return }
            after(0.2) { waitBubble(original) }
        }
        waitProse()
    }

    /// Hook for later steps.
    static var extra: @MainActor (EditorWindowController, String) -> Void = { tab, out in animations(tab, out: out) }

    /// The owl's animations, then the same under Reduce Motion.
    static func animations(_ tab: EditorWindowController, out: String) {
        guard let owl = tab.owl, let window = tab.window else { OwlCheck.finish(out); return }
        let v = owl.owl
        OwlView.reduceMotion = false
        owl.reduceMotionChanged()
        owl.chatCue(.asked)
        check(v.isPlaying && v.inState, "thinking loops while the AI works")
        owl.chatCue(.searching)
        check(v.isPlaying, "searching loops while a search tool runs")
        owl.chatCue(.stopped)
        check(!v.isPlaying && v.pose == .idle, "back to idle when the answer stops")
        owl.nod()
        check(v.isPlaying, "a nod plays after an edit is applied")
        // Typing stops a gesture at once.
        window.makeFirstResponder(tab.textView)
        OwlCheck.key(window, "y", code: 16, [])
        check(!v.isPlaying, "typing stops the gesture (never animates while typing)")
        let looks = owl.looks
        after(1.1) {
            owl.idleTickNow()
            check(owl.looks == looks + 1 && v.isPlaying, "after typing stops he looks toward the caret")
            v.stopSequence()
            // Reduce Motion.
            OwlView.reduceMotion = true
            owl.reduceMotionChanged()
            owl.chatCue(.asked)
            check(!v.isPlaying && v.pose == .thinking, "Reduce Motion: thinking is a still pose, no timer")
            owl.chatCue(.proposing)
            check(!v.isPlaying, "Reduce Motion: writing is a still pose")
            owl.chatCue(.stopped)
            owl.nod()
            v.flap()
            v.wave()
            check(!v.isPlaying, "Reduce Motion: no nod, flap or wave")
            owl.idleTickNow()
            check(!v.isPlaying, "Reduce Motion: an idle tick animates nothing")
            OwlCheck.snapshot(window, "\(out)/anim-reduce-motion.png") {
                OwlView.reduceMotion = OwlView.currentReduceMotion()
                OwlCheck.finish(out)
            }
        }
    }
}
