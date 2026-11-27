import AppKit
import CedricCore

/// CEDRIC_CHECK=help (Scripts/tools-check.sh): the Help menu is the
/// system's help menu (menu search), with Owlink Help and Keyboard
/// Shortcuts, and the shortcuts window lists the menus' shortcuts.
@MainActor
extension DevChecks {
    static func helpCheck(_ app: AppDelegate) {
        let tab = app.open(write("help.txt", "help\n"))!
        sized(tab)
        run([
            sync {
                let help = NSApp.mainMenu?.items.last
                expect(help?.title == "Help" && NSApp.helpMenu === help?.submenu, "Help is the last menu and the system's help menu")
                let titles = help?.submenu?.items.map(\.title) ?? []
                expect(titles.contains("Owlink Help") && titles.contains("Keyboard Shortcuts"), "with Owlink Help and Keyboard Shortcuts",
                       "\(titles)")
                expect(AppDelegate.helpURL == AboutInfo.help(version: CedricVersion.string)
                       && AppDelegate.helpURL.absoluteString.hasSuffix("/blob/v\(CedricVersion.string)/docs/MANUAL.md"),
                       "Help opens the manual at this release's tag", AppDelegate.helpURL.absoluteString)
                expect(titles.contains("Owlink on GitHub") && titles.contains("Report an Issue…"), "with Owlink on GitHub and Report an Issue…")
                let about = AboutPanel.options(AboutInfo.panelVersions(bundle: Bundle.main.infoDictionary))
                let credits = (about[.credits] as? NSAttributedString)?.string ?? ""
                expect(about[.version] as? String == "" && about[.applicationVersion] as? String == CedricVersion.string
                       && credits.contains("Made by d4rkwyng") && credits.contains("github.com/d4rkwyng/owlink")
                       && credits.contains("BSD-\u{2060}2-\u{2060}Clause") && credits.contains("llama.cpp")
                       && credits.contains("Sierra"), "About: version without build, author, link, licence, credits", credits)
                expect(NSApp.mainMenu?.items.first?.submenu?.items.first?.action == #selector(AppDelegate.showAbout(_:)), "About Owlink opens Owlink's panel")
                if let i = help?.submenu?.items.firstIndex(where: { $0.title == "Keyboard Shortcuts" }) {
                    help?.submenu?.performActionForItem(at: i)
                }
            },
            sync {
                let w = ShortcutsWindow.shared
                let text = ((w?.contentView as? NSScrollView)?.documentView as? NSTextView)?.string ?? ""
                expect(w?.isVisible == true, "Keyboard Shortcuts opens a window")
                expect(text.contains("⇧⌘T") && text.contains("File › Reopen Closed Tab") && text.contains("⌘S"),
                       "listing the menus' shortcuts", String(text.prefix(120)))
                expect(text.split(separator: "\n").count == MenuShortcuts.list().count + MenuShortcuts.extraRows.count,
                       "every one of them, and the non-menu ones (⌥-drag, ⌘-click, ⎋)")
                // The 0.2.0 keys, each on its own row with its item.
                let lines = text.split(separator: "\n").map(String.init)
                let wanted: [(String, String)] = [
                    ("⇧⌘O", "Open Folder"), ("⌃⌘1", "Folder Sidebar"), ("⌥⇧⌘F", "Replace in Files"),
                    ("⌘D", "Add Next Occurrence"), ("⌃⌘G", "Select All Occurrences"), ("⌃⇧↑", "Add Caret Above"),
                    ("⌃⇧↓", "Add Caret Below"), ("⌥-drag", "column selection"), ("⌘-click", "add or remove a caret"), ("⎋", "Single Caret"),
                ]
                let missing = wanted.filter { k, name in !lines.contains { $0.hasPrefix(k + " ") && $0.contains(name) } }
                expect(missing.isEmpty, "the 0.2.0 keys are listed: ⇧⌘O ⌃⌘1 ⌥⇧⌘F ⌘D ⌃⌘G ⌃⇧↑ ⌃⇧↓ ⌥-drag ⌘-click ⎋",
                       "missing \(missing.map(\.0)) in \(lines.filter { $0.contains("Caret") || $0.contains("Folder") || $0.contains("Occurrence") })")
            },
            { next in snapshot("keyboard-shortcuts.png", window: ShortcutsWindow.shared)(next) },
            // Updates (Updater.swift): Owlink › Check for Updates… right after About, disabled with a
            // tooltip; the Info.plist carries Owlink's committed feed and public key with automatic
            // checks on, yet a check build has no Sparkle and stays off; Settings' Automatically check
            // for updates off and disabled, and nothing written to the user's defaults.
            sync {
                ShortcutsWindow.shared?.close()
                let appMenu = NSApp.mainMenu?.items.first?.submenu
                let update = appMenu?.items.first { $0.action == #selector(AppDelegate.checkForUpdates(_:)) }
                expect(update?.title == "Check for Updates…" && update.flatMap { appMenu?.index(of: $0) } == 1,
                       "Owlink › Check for Updates… follows About Owlink", "\(appMenu?.items.map(\.title) ?? [])")
                appMenu?.update()
                expect(update?.isEnabled == false && update?.toolTip == UpdateConfig.disabled(.checkBuild).tooltip,
                       "Check for Updates… is disabled in a check build, with a tooltip", "\(update?.isEnabled == true) \(update?.toolTip ?? "nil")")
                expect(Updater.shared.config == .disabled(.checkBuild) && !Updater.shared.canCheck, "the updater is off in a check build")
                let info = Bundle.main.infoDictionary ?? [:]
                let feed = "https://owlink.app/appcast.xml", key = "hrWeLLjfQFt7O50s1x4JepXV7dXLmpEztAuhe1XcsQs="
                expect(info["SUFeedURL"] as? String == feed && info["SUPublicEDKey"] as? String == key
                       && info["SURequireSignedFeed"] as? Bool == true && info["SUEnableAutomaticChecks"] as? Bool == true
                       && info["SUAutomaticallyUpdate"] as? Bool == false,
                       "Info.plist: Owlink's feed and public key, signed feed required, automatic checks on, never installs without asking",
                       "\(info["SUFeedURL"] ?? "nil") \(info["SUPublicEDKey"] ?? "nil") \(info["SUEnableAutomaticChecks"] ?? "nil")")
                expect(UpdateConfig.from(info: info, checksEnabled: false) == .enabled(feed: URL(string: feed)!, publicKey: key),
                       "the same Info.plist in a release build turns the updater on, with that feed and key")
                let sparkle = Bundle.main.privateFrameworksURL?.appendingPathComponent("Sparkle.framework").path ?? "/"
                expect(!FileManager.default.fileExists(atPath: sparkle), "a check build has no Sparkle.framework", sparkle)
                SettingsWindowController.show(pane: .general)
                let box = SettingsWindowController.shared?.autoUpdates
                expect(box?.title == "Automatically check for updates" && box?.state == .off && box?.isEnabled == false
                       && box?.toolTip == UpdateConfig.disabled(.checkBuild).tooltip,
                       "Settings: Automatically check for updates is off and disabled, with the same tooltip")
                expect(UserDefaults.standard.object(forKey: UpdateConfig.automaticChecksKey) == nil
                       || UserDefaults.standard.bool(forKey: UpdateConfig.automaticChecksKey) == false,
                       "and nothing turned automatic checks on")
                SettingsWindowController.shared?.window?.close()
            },
        ])
    }
}

/// CEDRIC_CHECK=menus: no duplicate items (one visible New Tab, Check
/// Spelling While Typing only in Edit), ⌘N and ⌘T both open a tab, and
/// Wrap Lines is ⌥⌘Z (bare ⌥Z types Ω).
@MainActor
extension DevChecks {
    static func menusCheck(_ app: AppDelegate) {
        let tab = app.open(write("menus.txt", "menus\n"))!
        sized(tab)
        func menu(_ t: String) -> NSMenu? { NSApp.mainMenu?.items.first { $0.title == t }?.submenu }
        func press(_ ch: String) -> Bool {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                           windowNumber: tab.window?.windowNumber ?? 0, context: nil, characters: ch,
                                           charactersIgnoringModifiers: ch, isARepeat: false, keyCode: keyCodes[Character(ch)] ?? 0)
            else { return false }
            return NSApp.mainMenu?.performKeyEquivalent(with: e) == true
        }
        run([
            sync {
                let file = menu("File")?.items.filter { !$0.isHidden }.map(\.title) ?? []
                expect(file.filter { $0 == "New Tab" }.count == 1, "File shows New Tab once", "\(file)")
                let view = menu("View")?.items.map(\.title) ?? []
                expect(!view.contains("Check Spelling While Typing"), "View no longer repeats Check Spelling While Typing")
                // 0.4.1 (UX review #2): a Text menu between Edit and View; Compare and Follow File in File.
                let bar = NSApp.mainMenu?.items.map(\.title) ?? []
                expect(bar.firstIndex(of: "Text").map { $0 == (bar.firstIndex(of: "Edit") ?? -9) + 1 && bar[$0 + 1] == "View" } == true,
                       "a Text menu sits between Edit and View", "\(bar)")
                let text = menu("Text")?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
                expect(text == ["Selection", "Line", "Bookmarks", "Text Tools", "Indentation", "Folding"],
                       "Text holds Selection, Line, Bookmarks, Text Tools, Indentation and Folding", "\(text)")
                let edit = menu("Edit")?.items.map(\.title) ?? []
                expect(!edit.contains { ["Selection", "Line", "Bookmarks", "Text Tools"].contains($0) }, "Edit no longer holds them", "\(edit)")
                expect(!(menu("Format")?.items.map(\.title) ?? []).contains("Indentation"), "Format no longer holds Indentation")
                expect(!view.contains { ["Folding", "Compare With…", "Compare with Last Commit", "Next Difference",
                                         "Previous Difference", "Follow File"].contains($0) }, "View no longer holds Folding, Compare or Follow File", "\(view)")
                let compare = menu("File")?.items.first { $0.title == "Compare" }?.submenu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
                expect(compare == ["Compare With…", "Compare with Last Commit", "Next Difference", "Previous Difference"],
                       "File › Compare holds the comparison commands", "\(compare)")
                expect(menu("File")?.items.contains { $0.title == "Follow File" } == true, "File › Follow File")
                expect(menu("Text")?.items.first { $0.title == "Line" }?.submenu?.items.contains { $0.title == "Comment Selection" } == true,
                       "Comment Selection stays in Text › Line")
                let wrap = menu("View")?.items.first { $0.title == "Wrap Lines" }
                expect(wrap?.keyEquivalent == "z" && wrap?.keyEquivalentModifierMask == [.command, .option], "Wrap Lines is ⌥⌘Z")
                let before = app.tabs.count
                expect(press("n") && app.tabs.count == before + 1, "⌘N opens a tab", "\(app.tabs.count)")
                expect(press("t") && app.tabs.count == before + 2, "⌘T (hidden alias) still opens a tab", "\(app.tabs.count)")
            },
        ])
    }
}
