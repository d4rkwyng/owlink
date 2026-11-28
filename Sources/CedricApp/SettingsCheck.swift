import AppKit
import CedricCore
import CedricAI

/// CEDRIC_CHECK=settings: the tabbed, instant-apply Settings window
/// (0.4.1, UX review #1). Not built at launch, and each tab only when first
/// shown; ⌘, opens it on General the first time; four toolbar tabs whose
/// titles name the window; every popup, field and stepper has a VoiceOver
/// name; each View/Edit menu toggle and its checkbox move together (the
/// menu updates the box, the box updates the menu); Tab moves between the
/// fields; the window reopens on the tab it was left on; Cedric › Cedric AI
/// Settings… opens the Cedric tab, which has no Save or Cancel; the prose
/// font (ProseFontCheck.swift). Snapshots: settings-general/editor/writing/cedric.png.
/// Settings › Cedric on Built-in (run with CEDRIC_AI_BACKEND=builtIn, an
/// empty CEDRIC_MODELS_DIR and a CEDRIC_AI_DEFAULTS suite of its own, as
/// tools-check.sh does; without both folders isolated the check opens
/// nothing, CheckIsolation): one Model popup lists Automatic and every
/// catalog model with its tag, one action button on its row, one-line notes
/// (also as laid out on an Intel Mac), and the tab at most
/// `cedricTabMaxHeight` tall. A download target stays selected, with the
/// same menu items, through progress; an installed model (a stand-in in the
/// check's models folder) saves its ID to the suite, Automatic clears it,
/// and the standard defaults' AI settings are untouched.
/// CEDRIC_SETTINGS_APPEARANCE=light|dark (check only) draws the app, and so the
/// Settings window, in Aqua or Dark Aqua for this run; the system appearance
/// is left alone.
@MainActor
extension DevChecks {
    static let toggleActions: [MenuToggleSetting: Selector] = [
        .wrapLines: #selector(AppDelegate.toggleWrap(_:)),
        .showInvisibles: #selector(AppDelegate.toggleInvisibles(_:)),
        .showLineNumbers: #selector(AppDelegate.toggleLineNumbers(_:)),
        .highlightOccurrences: #selector(AppDelegate.toggleHighlightOccurrences(_:)),
        .autoCloseBrackets: #selector(AppDelegate.toggleAutoCloseBrackets(_:)),
        .checkSpellingWhileTyping: #selector(AppDelegate.toggleSpellingWhileTyping(_:)),
        .checkGrammar: #selector(AppDelegate.toggleGrammar(_:)),
    ]

    static func menuItem(_ action: Selector, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.action == action { return item }
            if let found = menuItem(action, in: item.submenu) { return found }
        }
        return nil
    }

    /// What the menu shows for the toggle once validated: a checkmark, or Hide X (on) / Show X (off).
    static func menuShowsOn(_ item: NSMenuItem, _ app: AppDelegate) -> Bool {
        _ = app.validateMenuItem(item)
        return item.title.hasPrefix("Hide ") || (!item.title.hasPrefix("Show ") && item.state == .on)
    }

    /// The Cedric tab's window height on Built-in, at most: 60% of the
    /// 826 pt the five-row download list took (0.6.0, before the compact
    /// Model chooser).
    static let cedricTabMaxHeight: CGFloat = 495

    static func settingsCheck(_ app: AppDelegate) {
        // Before Settings (and so BuiltInDownloads) exists: the AI settings and
        // models must be the check's own, or its clicks could save or delete the user's.
        if let why = CheckIsolation.problem() {
            expect(false, "isolated run: \(why); Settings not opened")
            finish()
            return
        }
        let standardAI = UserDefaults.standard.data(forKey: LocalAISettings.defaultsKey)
        // owlHintSource: applying an AI choice may switch the owl's hint source.
        let restore = keepDefaults(MenuToggleSetting.allCases.map(\.defaultsKey) + ["styleCheck", "owlHintSource", SettingsPane.defaultsKey])
        switch DevEnvironment.values["CEDRIC_SETTINGS_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        let a = app.open(write("a.md", "# Notes\n\nSome text.\n"))!
        sized(a)
        var s: SettingsWindowController? { SettingsWindowController.shared }
        func all(_ v: NSView?) -> [NSView] { guard let v else { return [] }; return v.subviews + v.subviews.flatMap { all($0) } }
        func steps(for pane: SettingsPane) -> [(@escaping () -> Void) -> Void] {
            [
                sync {
                    guard let s else { return }
                    s.select(pane)
                    let title = SettingsWindowController.paneTitle(pane)
                    expect(s.selectedPane == pane && s.window?.title == title, "\(title): selected, and the window is titled \(title)", s.window?.title ?? "-")
                    let content = all(s.panes[pane]?.view)
                    let named = content.filter { $0 is NSPopUpButton || $0 is NSStepper || (($0 as? NSTextField)?.isEditable == true) }
                    let unnamed = named.filter { ($0.accessibilityLabel() ?? "").isEmpty && $0.accessibilityTitleUIElement() == nil }
                    expect(!named.isEmpty || pane == .general, "\(title): has controls (\(named.count) popups, fields, steppers)")
                    expect(unnamed.isEmpty, "\(title): each popup, field and stepper has a VoiceOver name", "\(unnamed.map { String(describing: Swift.type(of: $0)) })")
                    // (Default editor for…'s list scrolls: its boxes may be out of view.)
                    let boxes = content.compactMap { $0 as? NSButton }.filter { $0.bezelStyle != .push && !$0.title.isEmpty && $0.enclosingScrollView == nil }
                    let visible = s.window.map { w in boxes.allSatisfy { NSContainsRect(w.contentView!.bounds, $0.convert($0.bounds, to: w.contentView)) || $0.isHiddenOrHasHiddenAncestor } } ?? false
                    expect(visible, "\(title): the window fits the tab (no control cut off)", "\(s.window?.frame.size ?? .zero)")
                    let size = s.window?.frame.size ?? .zero
                    print("check: info \(title) window \(Int(size.width)) x \(Int(size.height)) pt")
                },
                { next in snapshot("settings-\(pane.rawValue).png", window: SettingsWindowController.shared?.window)(next) },
            ]
        }
        var plan: [(@escaping () -> Void) -> Void] = [
            sync {
                expect(SettingsWindowController.shared == nil, "the Settings window isn't built at launch")
                focus(a)
                key(",", [.command])
            },
            sync {
                guard let s else { expect(false, "⌘, opens Settings"); return }
                expect(s.window?.isVisible == true && s.selectedPane == .general, "⌘, opens Settings on General the first time")
                expect(s.window?.toolbar != nil && s.tabs.tabStyle == .toolbar, "the tabs are toolbar items")
                let labels = s.tabs.tabViewItems.map(\.label)
                expect(labels == ["General", "Editor", "Writing", "Cedric"], "four tabs: General, Editor, Writing, Cedric", "\(labels)")
                expect(s.tabs.tabViewItems.allSatisfy { $0.image != nil }, "each tab has an icon")
                expect(s.panes[.cedric]?.isViewLoaded == false && s.ai == nil, "the Cedric tab (and its AI engine list) isn't built until shown")
                expect(s.panes[.editor]?.isViewLoaded == false, "nor is the Editor tab")
            },
        ]
        for p in SettingsPane.allCases { plan += steps(for: p) }
        plan += [
            sync {
                // Settings › Cedric, Built-in: the compact Model chooser.
                guard let s, let w = s.window else { return }
                s.select(.cedric)
                guard let ai = s.ai else { expect(false, "Cedric: the AI section is built"); return }
                guard ai.settings.backend == .builtIn else {
                    expect(false, "Cedric: on Built-in for the compact chooser checks (run with CEDRIC_AI_BACKEND=builtIn)", ai.settings.backend.rawValue)
                    return
                }
                let catalog = BuiltInDownloads.shared.catalog?.models ?? []
                let installed = catalog.filter { BuiltInDownloads.shared.state($0) == .installed }
                expect(catalog.count == 5 && installed.isEmpty, "Cedric: five catalog models, none downloaded (an empty CEDRIC_MODELS_DIR)", "\(catalog.count), \(installed.map(\.id))")
                let content = all(s.panes[.cedric]?.view).filter { !$0.isHiddenOrHasHiddenAncestor }
                let ids = Set(catalog.map(\.id))
                let choosers = content.compactMap { $0 as? NSPopUpButton }.filter { $0.itemArray.contains { ids.contains($0.representedObject as? String ?? "") } }
                expect(choosers.count == 1 && choosers.first === ai.modelPopup, "Cedric: one Model popup chooses the built-in model", "\(choosers.count)")
                let titles = ai.modelPopup.itemArray.map(\.title)
                expect(titles == [BuiltInModel.automaticTitle(suggested: nil)] + catalog.map(\.menuTitle),
                       "…Automatic, then every catalog model with its tag", "\(titles)")
                expect(titles.first == "Automatic (download a model)" && ai.modelPopup.indexOfSelectedItem == 0, "…on Automatic (download a model)", "\(ai.modelPopup.titleOfSelectedItem ?? "-")")
                let tagged = catalog.filter { $0.isNonCommercial && !$0.isDefault }
                expect(!tagged.isEmpty && tagged.allSatisfy { m in titles.contains("\(m.name) (non-commercial)") }, "…a non-commercial model says so in the menu", "\(titles)")
                expect(ai.modelPopup.accessibilityLabel() == "Model", "…VoiceOver calls it Model (not Download)", ai.modelPopup.accessibilityLabel() ?? "-")
                let v = ai.modelsView
                let actions = content.compactMap { $0 as? NSButton }.filter { ["Download", "Pause", "Resume", "Delete", "Cancel"].contains($0.title) }
                expect(actions.count == 1 && actions.first === v.action, "Cedric: no five-row list, one Download button", "\(actions.map(\.title))")
                expect(v.controls.superview === ai.modelRow && ai.modelPopup.superview === ai.modelRow
                       && v.action.superview === v.controls && v.secondary.superview === v.controls,
                       "…on the Model row, where Cancel goes too")
                let def = BuiltInDownloads.shared.catalog?.defaultModel
                expect(v.model == def && v.automatic && v.action.title == "Download", "…for the model Automatic would use (\(def?.name ?? "-"))")
                for b in [v.action, v.info] {
                    expect(!(b.accessibilityLabel() ?? "").isEmpty, "…\(b === v.info ? "the info button" : "the action button") has a VoiceOver name", b.accessibilityLabel() ?? "-")
                }
                expect(v.action.accessibilityLabel() == "Download \(def?.name ?? "")", "…naming the model", v.action.accessibilityLabel() ?? "-")
                expect(v.info.toolTip == def?.details && ai.modelPopup.toolTip == def?.details, "…its full description (license, memory, source) is the tooltip")
                expect(v.status.stringValue.contains("Not downloaded"), "Cedric: one status line", v.status.stringValue)
                let titlesShown = content.compactMap { ($0 as? NSButton)?.title }
                expect(titlesShown.contains("Test Connection") && titlesShown.contains("Check automatically when I pause typing") && titlesShown.contains("Load model at launch"),
                       "Cedric: Test Connection and the checkboxes stay", "\(titlesShown)")
                expect(!ai.intervalPopup.isHiddenOrHasHiddenAncestor, "Cedric: Check at most every stays")
                for l in [ai.privacyLabel, ai.launchNote, v.status, v.source] {
                    expect(!l.isHiddenOrHasHiddenAncestor && oneLine(l), "Cedric: one line: \(l.stringValue.prefix(40))…", "\(l.frame.height) pt")
                }
                // The Intel notes, where this Mac shows them (an Intel layout is checked below).
                for l in [ai.noteLabel, ai.automaticNote] where !l.isHiddenOrHasHiddenAncestor {
                    expect(oneLine(l), "Cedric: one line: \(l.stringValue.prefix(40))…", "\(l.frame.height) pt")
                }
                expect(ai.privacyLabel.stringValue == LocalAISettings.privacyNoteOnDevice, "Cedric: the on-device privacy note stays in view")
                expect(ai.launchNote.toolTip == LocalAISettings.loadModelAtLaunchNote, "…the full Load model at launch note is its tooltip")
                expect(v.source.toolTip?.contains("Hugging Face") == true && v.source.toolTip?.contains(BuiltInDownloads.shared.store.directory.lastPathComponent) == true,
                       "…the Hugging Face folder is the source line's tooltip", v.source.toolTip ?? "-")
                let items = ai.modelPopup.itemArray
                v.reload()   // as each download progress tick does
                expect(items.count == ai.modelPopup.numberOfItems && zip(items, ai.modelPopup.itemArray).allSatisfy { $0 === $1 },
                       "Cedric: a download-state refresh leaves the Model menu's items alone (an open menu isn't rebuilt)")
                let h = w.frame.height
                expect(h <= cedricTabMaxHeight, "Cedric: the tab is at most \(Int(cedricTabMaxHeight)) pt tall (was 826)", "\(Int(h)) pt")
                // Picking a model that isn't downloaded makes it the download
                // target; Automatic stays in effect (nothing is saved).
                guard let nc = tagged.first, let i = ai.modelPopup.itemArray.firstIndex(where: { $0.representedObject as? String == nc.id }) else { return }
                let applied = ai.applyCount
                ai.modelPopup.selectItem(at: i)
                NSApp.sendAction(ai.modelPopup.action!, to: ai.modelPopup.target, from: ai.modelPopup)
                expect(ai.settings.model == nil && ai.applyCount == applied, "Cedric: picking \(nc.name) (not downloaded) keeps Automatic", ai.settings.model ?? "nil")
                expect(ai.builtInTarget == nc.id && ai.modelPopup.titleOfSelectedItem == nc.menuTitle && v.model == nc && !v.automatic,
                       "…the popup shows it as the download target", ai.modelPopup.titleOfSelectedItem ?? "-")
                expect(v.action.title == "Download" && v.action.accessibilityLabel() == "Download \(nc.name)" && v.status.stringValue.hasPrefix("Not downloaded"),
                       "…with its own Download and status", v.status.stringValue)
                expect(w.frame.height <= cedricTabMaxHeight, "…and the window stays compact", "\(Int(w.frame.height)) pt")
            },
            { next in snapshot("settings-cedric-target.png", window: SettingsWindowController.shared?.window)(next) },
            sync {
                // The target through a download's progress (as the downloader
                // reports it; nothing is downloaded): it stays selected, the
                // menu keeps its items, nothing is saved.
                guard let ai = s?.ai, let w = s?.window, ai.settings.backend == .builtIn,
                      let id = ai.builtInTarget, let m = BuiltInDownloads.shared.catalog?.model(id: id) else {
                    expect(false, "Cedric: a download target is selected for the progress checks"); return
                }
                let v = ai.modelsView
                let items = ai.modelPopup.itemArray
                let applied = ai.applyCount
                let t = m.sizeBytes
                for (state, button, prefix) in [(ModelDownloadState.downloading(received: t / 10, total: t), "Pause", "Downloading"),
                                                 (.downloading(received: t / 4, total: t), "Pause", "Downloading"),
                                                 (.paused(received: t / 4, total: t), "Resume", "Paused")] {
                    BuiltInDownloads.shared.simulateForCheck(m.id, state)
                    let same = items.count == ai.modelPopup.numberOfItems && zip(items, ai.modelPopup.itemArray).allSatisfy { $0 === $1 }
                    expect(same, "Cedric: \(prefix.lowercased()) \(Int((state.fraction ?? 0) * 100))%: the Model menu keeps its items")
                    expect(ai.builtInTarget == m.id && ai.modelPopup.selectedItem?.representedObject as? String == m.id && v.model == m && !v.automatic,
                           "…and \(m.name) stays selected", ai.modelPopup.titleOfSelectedItem ?? "-")
                    expect(ai.settings.model == nil && ai.applyCount == applied, "…nothing saved", ai.settings.model ?? "nil")
                    expect(v.action.title == button && !v.secondary.isHidden && v.secondary.title == "Cancel" && !v.progress.isHidden
                           && v.status.stringValue.hasPrefix(prefix) && oneLine(v.status), "…\(button) and Cancel, one status line", v.status.stringValue)
                    expect(w.frame.height <= cedricTabMaxHeight, "…the window stays compact", "\(Int(w.frame.height)) pt")
                }
                BuiltInDownloads.shared.simulateForCheck(m.id, .notDownloaded)
                expect(ai.builtInTarget == m.id && v.action.title == "Download" && v.secondary.isHidden, "Cedric: cancelled, \(m.name) is still the target with Download")
            },
            sync {
                guard let ai = s?.ai, ai.settings.backend == .builtIn else { return }
                let applied = ai.applyCount
                ai.modelPopup.selectItem(at: 0)
                NSApp.sendAction(ai.modelPopup.action!, to: ai.modelPopup.target, from: ai.modelPopup)
                expect(ai.builtInTarget == nil && ai.settings.model == nil && ai.applyCount == applied && ai.modelsView.automatic,
                       "Cedric: Automatic again clears the target, still nothing saved")
            },
            sync {
                // As on an Intel Mac: the engine caveat and the automatic-check
                // note show, each one short line with the full text as its tooltip.
                guard let ai = s?.ai, ai.settings.backend == .builtIn else { return }
                AISettingsSection.intelLayoutForCheck = true
                ai.modelsView.reload()
            },
            sync {
                guard let ai = s?.ai, let w = s?.window, ai.settings.backend == .builtIn else { return }
                for (l, short, full) in [(ai.noteLabel, AISettingsSection.builtInSlowNote, BuiltInEngine.slowHardwareNote),
                                         (ai.automaticNote, AISettingsSection.builtInIntelAutomaticNote, AISettingsSection.intelAutomaticNote)] {
                    expect(!l.isHiddenOrHasHiddenAncestor && l.stringValue == short && l.toolTip == full, "Cedric (Intel layout): \(short)", l.stringValue)
                    expect(oneLine(l) && l.frame.width >= ceil(l.attributedStringValue.size().width), "…one line, not truncated", "\(l.frame.size)")
                }
                let h = w.frame.height
                print("check: info Cedric (Intel layout) window \(Int(w.frame.width)) x \(Int(h)) pt")
                expect(h <= cedricTabMaxHeight, "Cedric (Intel layout): the tab is at most \(Int(cedricTabMaxHeight)) pt tall", "\(Int(h)) pt")
            },
            { next in snapshot("settings-cedric-intel.png", window: SettingsWindowController.shared?.window)(next) },
            sync {
                guard let ai = s?.ai, ai.settings.backend == .builtIn else { return }
                AISettingsSection.intelLayoutForCheck = false
                ai.modelsView.reload()
                expect(LlamaRuntime.isSlowHardware || (ai.noteLabel.isHiddenOrHasHiddenAncestor && ai.automaticNote.isHiddenOrHasHiddenAncestor),
                       "Cedric: back to this Mac's layout (no Intel notes)")
            },
        ]
        plan += installedModelSteps(standardAI: standardAI)
        plan += [
            sync {
                guard let s else { return }
                s.select(.editor)
                // Menu → box, box → menu, for every toggle.
                for t in MenuToggleSetting.allCases {
                    guard let box = s.toggles[t], let sel = toggleActions[t], let item = menuItem(sel) else {
                        expect(false, "\(t.rawValue): box and menu item exist"); continue
                    }
                    if t.pane != s.selectedPane { s.select(t.pane) }
                    let before = Settings.shared[toggle: t]
                    expect((box.state == .on) == before && menuShowsOn(item, app) == before, "\(box.title): box and menu agree (\(before ? "on" : "off"))")
                    NSApp.sendAction(sel, to: app, from: item)
                    expect(Settings.shared[toggle: t] == !before && (box.state == .on) == !before,
                           "\(item.title): the menu item changes the setting and the box follows")
                    box.performClick(nil)
                    expect(Settings.shared[toggle: t] == before && menuShowsOn(item, app) == before,
                           "\(box.title): the box changes it back and the menu shows it")
                    expect(box.window != nil && !box.isHiddenOrHasHiddenAncestor, "\(box.title): on the \(t.pane.rawValue) tab")
                }
            },
            sync {
                // Keyboard: Tab moves through the Writing tab's fields.
                guard let s, let w = s.window else { return }
                s.select(.writing)
                Settings.shared.styleCheck = true
                w.recalculateKeyViewLoop()
                expect(w.makeFirstResponder(s.readableColumns), "the readable width field takes focus")
                var seen: [NSView] = [s.readableColumns]
                var v: NSView? = s.readableColumns.nextValidKeyView
                while let cur = v, !seen.contains(where: { $0 === cur }), seen.count < 30 { seen.append(cur); v = cur.nextValidKeyView }
                expect(seen.contains { $0 === s.styleExtra } && seen.contains { $0 === s.styleExceptions },
                       "Tab reaches Also flag and Never flag", "\(seen.map { String(describing: Swift.type(of: $0)) })")
                Settings.shared.styleCheck = false
            },
            sync {
                guard let s else { return }
                s.select(.writing)
                s.window?.close()
                SettingsWindowController.show()
                expect(s.selectedPane == .writing, "Settings reopens on the tab it was left on (Writing)")
                expect(SettingsWindowController.savedPane == .writing, "…which it remembers")
                s.window?.close()
                NSApp.sendAction(#selector(AppDelegate.showAISettings(_:)), to: app, from: nil)
                expect(s.window?.isVisible == true && s.selectedPane == .cedric, "Cedric › Cedric AI Settings… opens Settings on the Cedric tab")
                let titles = all(s.window?.contentView).compactMap { ($0 as? NSButton)?.title }
                expect(s.ai != nil && titles.contains("Test Connection"), "the Cedric tab holds the AI settings", "\(titles)")
                expect(!titles.contains("Save") && !titles.contains("Cancel"), "no Save or Cancel")
                let windows = NSApp.windows.filter { $0.isVisible && $0.title == "Cedric AI" }
                expect(windows.isEmpty, "no separate Cedric AI window")
                let item = menuItem(#selector(AppDelegate.showAISettings(_:)))
                expect(item?.title == "Cedric AI Settings…", "the Cedric menu keeps Cedric AI Settings…")
            },
        ]
        plan += proseFontSteps(app)
        plan += [
            sync {
                s?.window?.close()
                restore()
                NSApp.appearance = nil
                NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
            },
        ]
        run(plan)
    }

    /// One line of its font (a wrapping label that wrapped is taller).
    static func oneLine(_ l: NSTextField) -> Bool {
        let line = NSLayoutManager().defaultLineHeight(for: l.font ?? .systemFont(ofSize: NSFont.smallSystemFontSize))
        return l.frame.height < line * 1.6
    }

    /// Built-in, with the check's own models folder and defaults suite
    /// (CheckIsolation, checked before Settings opened): a stand-in
    /// "installed" model (a sparse file of the catalog's size and its
    /// .verified marker, as owl-check.sh makes) is a choice, so picking it
    /// saves its ID; Automatic clears it. A saved ID the catalog doesn't
    /// list says so. The standard defaults' AI settings stay as they were.
    static func installedModelSteps(standardAI: Data?) -> [Step] {
        var ai: AISettingsSection? { SettingsWindowController.shared?.ai }
        let downloads = BuiltInDownloads.shared
        guard let m = downloads.catalog?.defaultModel ?? downloads.catalog?.models.first else {
            return [sync { expect(false, "Cedric: a catalog model for the installed-model checks") }]
        }
        let file = downloads.store.fileURL(for: m)
        let marker = downloads.store.directory.appendingPathComponent(m.fileName + ".verified")
        func saved() -> LocalAISettings { LocalAISettings.load(from: AIStore.defaults) }
        let legacy = "qwen-legacy-check-model"
        return [
            sync {
                guard CheckIsolation.problem() == nil, ai?.settings.backend == .builtIn else { expect(false, "Cedric: isolated, on Built-in"); return }
                FileManager.default.createFile(atPath: file.path, contents: nil)
                if let h = try? FileHandle(forWritingTo: file) { try? h.truncate(atOffset: UInt64(m.sizeBytes)); try? h.close() }
                try? (m.sha256 + "\n").write(to: marker, atomically: true, encoding: .utf8)
                downloads.rescanForCheck()
                expect(downloads.state(m) == .installed, "Cedric: a stand-in \(m.name) is installed in the check's models folder")
            },
            sync {
                guard let ai, let i = ai.modelPopup.itemArray.firstIndex(where: { $0.representedObject as? String == m.id }) else {
                    expect(false, "Cedric: \(m.name) is in the Model menu"); return
                }
                let applied = ai.applyCount
                ai.modelPopup.selectItem(at: i)
                NSApp.sendAction(ai.modelPopup.action!, to: ai.modelPopup.target, from: ai.modelPopup)
                expect(ai.builtInTarget == nil && ai.settings.model == m.id && ai.applyCount == applied + 1,
                       "Cedric: picking installed \(m.name) chooses it", ai.settings.model ?? "nil")
                expect(ai.modelsView.model == m && ai.modelsView.action.title == "Delete", "…its button is Delete", ai.modelsView.action.title)
            },
            waitFor("the suite saves \(m.id)") { saved().model == m.id && !AISettingsSection.applier.isBusy },
            sync {
                expect(saved().model == m.id, "Cedric: \(m.id) is saved to the check's defaults suite", saved().model ?? "nil")
                guard let ai else { return }
                let applied = ai.applyCount
                ai.modelPopup.selectItem(at: 0)
                NSApp.sendAction(ai.modelPopup.action!, to: ai.modelPopup.target, from: ai.modelPopup)
                expect(ai.settings.model == nil && ai.applyCount == applied + 1 && ai.modelsView.automatic, "Cedric: Automatic clears the choice", ai.settings.model ?? "nil")
                expect(ai.modelPopup.titleOfSelectedItem?.contains(m.id) == true, "…and uses the installed model", ai.modelPopup.titleOfSelectedItem ?? "-")
            },
            waitFor("the suite saves Automatic") { saved().model == nil && !AISettingsSection.applier.isBusy },
            sync {
                expect(saved().model == nil, "Cedric: Automatic (no model) is saved to the check's defaults suite", saved().model ?? "nil")
                // A saved ID the catalog doesn't list (an older build's, CEDRIC_AI_MODEL).
                var old = saved()
                old.model = legacy
                old.save(to: AIStore.defaults)
                ai?.reloadIfIdle()
            },
            sync {
                guard let ai else { return }
                let v = ai.modelsView
                expect(ai.settings.model == legacy && ai.modelPopup.titleOfSelectedItem == legacy, "Cedric: a saved model the catalog doesn't list stays selected",
                       ai.modelPopup.titleOfSelectedItem ?? "-")
                expect(v.model == nil && v.unavailableID == legacy && v.status.stringValue.contains("isn’t in this build’s model list")
                       && !v.status.stringValue.contains("No models are bundled") && v.status.toolTip == v.status.stringValue,
                       "…its status says it isn't in this build (tooltip too)", v.status.stringValue)
                expect(ai.modelPopup.numberOfItems == 2 + (downloads.catalog?.models.count ?? 0), "…next to Automatic and every catalog model", "\(ai.modelPopup.numberOfItems)")
                var back = saved()
                back.model = nil
                back.save(to: AIStore.defaults)
                ai.reloadIfIdle()
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: marker)
                downloads.rescanForCheck()
                expect(ai.settings.model == nil && downloads.state(m) == .notDownloaded, "Cedric: back to Automatic, the stand-in removed")
                expect(UserDefaults.standard.data(forKey: LocalAISettings.defaultsKey) == standardAI, "Cedric: the standard defaults' AI settings are untouched")
            },
        ]
    }
}
