import AppKit
import CedricCore
import CedricAI

#if DEBUG
/// CEDRIC_OWL_CHECK_BUILTIN=1 (Scripts/owl-check.sh): the freeze path,
/// in the app. The built-in engine, automatic checks on, "Rules + AI",
/// "Load model at launch" off (the settings of the Mac that froze), with
/// every wait shortened. CEDRIC_BUILTIN_SPY=1 puts a spy where llama.cpp
/// would be, so even a broken gate can't load a real model here, and
/// CEDRIC_MODELS_DIR holds a stand-in "installed" model.
///
///   1. Opening, typing and idling past every wait loads nothing and asks
///      nothing: an automatic check was due and held back; no thinking, no
///      bubble about the AI; the popover's status line says automatic
///      hints start after you ask (snapshot builtin-1-status).
///   2. Ask AI Now loads the model (once); after that a pause in typing
///      runs an automatic check on it, without another load.
///   3. The watchdog's notice: a bubble with OK, no sheet, no alert, the
///      window keeps focus (snapshot builtin-2-notice).
///   4. Settings › Cedric shows "Load model at launch", off, with its note
///      (snapshot builtin-3-settings).
@MainActor
enum BuiltInGateCheck {
    static func check(_ ok: Bool, _ what: String) { OwlCheck.check(ok, what) }

    static func run(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window, let owl = tab.owl else { OwlCheck.finish(out); return }
        let hub = OwlHub.shared
        let host = BuiltInModelHost.shared
        let spy = SpyBuiltInRuntime.shared
        hub.appActiveChanged()
        AICheck.wait("the built-in engine", timeout: 10, { hub.ai.isActive }) { ok in
            check(ok, "the built-in engine registered")
            check(hub.ai.engineTitle == "Built-in", "the engine is Built-in (\(hub.ai.engineTitle ?? "none"))")
            check(hub.ai.isAutomatic && !hub.ai.isPaused, "automatic checks on, Rules + AI")
            check(!AIStore.load().loadModelAtLaunch, "Load model at launch is off (the default)")
            check(!hub.ai.automaticAllowedNow, "automatic AI waits for the user to ask")
            OwlRulesCheck.typeAtEnd(tab, "// still here\n")
            // Pause 0.5 s, min idle 1 s, interval 1 s: an automatic check
            // was due several times over.
            OwlCheck.after(4) {
                Task { @MainActor in
                    let attempts = await host.loadAttempts
                    let requests = await hub.ai.scheduler?.requestCount ?? -1
                    let gated = await hub.ai.scheduler?.gatedAutomatic ?? 0
                    check(spy.loads == 0 && attempts == 0, "opening, typing and idling loaded no model (\(spy.loads) loads, \(attempts) attempts)")
                    check(requests == 0 && spy.requests == 0, "and asked nothing (\(requests) requests)")
                    check(gated >= 1, "an automatic check was due and held back (\(gated))")
                    check(hub.ai.lastCheck == nil && hub.ai.thinking.isEmpty, "no check ran, the owl never thought")
                    check(owl.presentedHint.map { $0.hint.source == "rules" } ?? true, "no bubble about the AI")
                    let status = hub.ai.statusLine() ?? ""
                    check(status == "Built-in · automatic hints start after you ask Cedric", "status: \(status)")
                    owl.hideBubble()
                    OwlHistoryCapCheck.openPopover(owl) { ok in
                        check(ok, "the popover opened")
                        OwlHistoryCapCheck.shot(owl.popoverWindow, "\(out)/builtin-1-status.png") {
                            owl.closePopover()
                            ask(tab, owl: owl, window: window, out: out)
                        }
                    }
                }
            }
        }
    }

    static func ask(_ tab: EditorWindowController, owl: OwlController, window: NSWindow, out: String) {
        let hub = OwlHub.shared
        let spy = SpyBuiltInRuntime.shared
        check(hub.askAI(in: tab), "Ask AI Now started a check")
        AICheck.wait("the asked-for load", timeout: 10, { spy.loads == 1 && hub.ai.lastCheck != nil }) { ok in
            check(ok, "Ask AI Now loaded the model once and checked (\(spy.loads) loads)")
            check(BuiltInModelHost.shared.session.explicitlyLoaded && hub.ai.automaticAllowedNow,
                  "the session remembers the user loaded it")
            OwlRulesCheck.typeAtEnd(tab, "// and again\n")
            AICheck.wait("an automatic check", timeout: 10, { spy.requests >= 2 }) { ok in
                check(ok, "a pause in typing now runs an automatic check (\(spy.requests) requests)")
                check(spy.loads == 1, "on the loaded model, no second load (\(spy.loads))")
                notice(tab, owl: owl, window: window, out: out)
            }
        }
    }

    static func notice(_ tab: EditorWindowController, owl: OwlController, window: NSWindow, out: String) {
        let hub = OwlHub.shared
        owl.hideBubble()
        let key = NSApp.keyWindow
        hub.builtInModelUnhealthy(seconds: Int(BuiltInWatchdog.seconds))
        AICheck.wait("the notice", timeout: 3, { owl.bubble != nil }) { ok in
            check(ok && owl.presentedHint?.hint.id == OwlController.builtInUnhealthyID, "the owl says the model didn't finish loading")
            check(hub.unhealthyNotices == 1, "once")
            check(owl.presentedHint?.hint.title == "The built-in model didn’t finish loading", "title: \(owl.presentedHint?.hint.title ?? "")")
            check(owl.presentedHint?.hint.detail?.contains("Automatic AI is off for now") == true, "it says automatic AI is off")
            check(owl.bubble?.buttons.map(\.title) == [String(localized: "OK")], "just OK (\(owl.bubble?.buttons.map(\.title) ?? []))")
            check(NSApp.modalWindow == nil && window.attachedSheet == nil, "no alert, no sheet")
            check(owl.bubble?.sourceLabel == nil, "not labelled as an AI suggestion")
            check(NSApp.keyWindow === key, "focus stays where it was")
            OwlHistoryCapCheck.shot(window, "\(out)/builtin-2-notice.png") {
                owl.bubble?.buttons.first?.performClick(nil)
                OwlCheck.after(0.3) {
                    check(owl.bubble == nil, "OK dismisses it")
                    settings(out: out)
                }
            }
        }
    }

    static func settings(out: String) {
        guard let app = NSApp.delegate as? AppDelegate else { OwlCheck.finish(out); return }
        NSApp.sendAction(#selector(AppDelegate.showAISettings(_:)), to: app, from: nil)
        guard let panel = SettingsWindowController.shared?.window, let section = SettingsWindowController.shared?.ai else {
            check(false, "Settings opened on the Cedric tab"); OwlCheck.finish(out); return
        }
        OwlCheck.after(0.4) {
            let box = section.launchBox
            check(!box.isHiddenOrHasHiddenAncestor, "Load model at launch is shown for Built-in")
            check(box.title == "Load model at launch" && box.state == .off, "titled, and off (\(box.state.rawValue))")
            check(section.launchNote.stringValue == LocalAISettings.loadModelAtLaunchNote && !section.launchNote.isHiddenOrHasHiddenAncestor,
                  "with its note")
            OwlHistoryCapCheck.shot(panel, "\(out)/builtin-3-settings.png") {
                panel.close()
                OwlCheck.finish(out)
            }
        }
    }
}
#endif
