import AppKit
import CedricCore

// Cedric: a fast, simple native text editor. AppKit, no storyboard: the
// menus are built here.

@MainActor
func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command,
          represented: Any? = nil) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
    i.keyEquivalentModifierMask = mods
    i.representedObject = represented
    return i
}

/// A menu item that isn't shown but whose shortcut still works.
@MainActor
func hiddenAlias(_ i: NSMenuItem) -> NSMenuItem {
    i.isHidden = true
    i.allowsKeyEquivalentWhenHidden = true
    return i
}

@MainActor
func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let menu = NSMenu(title: title)
    items.forEach(menu.addItem)
    parent.submenu = menu
    return parent
}

/// Text › Text Tools, with their key equivalents (⌃⌘ + a letter; ⇧ for
/// the inverse). `CEDRIC_DUMP_SHORTCUTS=1` lists every shortcut and fails
/// on a clash.
let textToolShortcuts: [(TextTool?, String, NSEvent.ModifierFlags)] = [
    (.sortAscending, "s", [.control, .command]),
    (.sortDescending, "s", [.control, .command, .shift]),
    (.sortNumeric, "s", [.control, .command, .option]),
    (.removeDuplicateLines, "r", [.control, .command]),
    (.reverseLines, "r", [.control, .command, .shift]),
    (.joinLines, "j", [.control, .command]),
    (.trimTrailingWhitespace, "w", [.control, .command]),
    (nil, "", []),
    (.uppercase, "u", [.control, .command]),
    (.lowercase, "l", [.control, .command]),
    (.titleCase, "t", [.control, .command]),
    (nil, "", []),
    (.jsonPrettyPrint, "j", [.control, .command, .option]),
    (.jsonMinify, "j", [.control, .command, .option, .shift]),
    (.xmlPrettyPrint, "x", [.control, .command, .option]),
    (nil, "", []),
    (.base64Encode, "b", [.control, .command]),
    (.base64Decode, "b", [.control, .command, .shift]),
    (.urlEncode, "e", [.control, .command]),
    (.urlDecode, "e", [.control, .command, .shift]),
]

@MainActor
func textToolItems() -> [NSMenuItem] {
    textToolShortcuts.map { tool, key, mods in
        guard let tool else { return .separator() }
        return item(tool.displayName, #selector(AppDelegate.textToolMenu(_:)), key, mods, represented: tool.rawValue)
    } + [
        // Explain & tidy (OwlTools.swift): offline, on demand.
        .separator(),
        item(String(localized: "Explain Regex"), #selector(AppDelegate.explainRegexMenu(_:))),
        item(String(localized: "Decode Selection"), #selector(AppDelegate.decodeSelectionMenu(_:))),
        item(String(localized: "Find TODOs"), #selector(AppDelegate.findTodosMenu(_:))),
    ]
}

/// The Cedric menu (0.4.0 UX polish, review #4): every command of Cedric,
/// the assistant, in one place, after Format and before Window (HIG: an
/// app's own menus go between View and Window). "Cedric" names the
/// assistant everywhere; "Owlink" only the app.
@MainActor
func cedricMenu() -> NSMenuItem {
    submenu(String(localized: "Cedric"), [
        item(String(localized: "Ask Cedric…"), #selector(AppDelegate.askCedricMenu(_:)), "/", [.command, .option]),
        item(String(localized: "Explain Selection"), #selector(AppDelegate.explainSelectionMenu(_:)), "e", [.command, .option]),
        item(String(localized: "Rewrite Selection"), #selector(AppDelegate.rewriteSelectionMenu(_:)), "e", [.command, .option, .shift]),
        item(String(localized: "Check Grammar with Cedric"), #selector(AppDelegate.checkGrammarWithAIMenu(_:))),
        item(String(localized: "Check Script for Risks…"), #selector(AppDelegate.scriptSafetyMenu(_:))),
        .separator(),
        item(String(localized: "Show Cedric"), #selector(AppDelegate.toggleOwl(_:))),
        submenu(String(localized: "Cedric’s Hints"), OwlHintSource.allCases.map {
            item($0 == .rules ? String(localized: "Rules") : String(localized: "Rules + AI"),
                 #selector(AppDelegate.pickOwlHintSource(_:)), represented: $0.rawValue)
        }),
        .separator(),
        item(String(localized: "Cedric AI Settings…"), #selector(AppDelegate.showAISettings(_:))),
    ])
}

/// The Text menu (0.4.1, UX review #2), between Edit and View as in BBEdit
/// (Text) and Xcode (Editor): the commands that change or move through the
/// text itself, taken out of Edit (Selection, Line, Bookmarks, Text Tools),
/// View (Folding) and Format (Indentation). Edit keeps the standard
/// clipboard, find and spelling commands; every shortcut is unchanged.
@MainActor
func textMenu() -> NSMenuItem {
    submenu(String(localized: "Text"), [
        // Multiple carets and column selection (MultiCaretEditing.swift).
        submenu(String(localized: "Selection"), [
            item(String(localized: "Add Next Occurrence"), #selector(AppDelegate.addNextOccurrenceMenu(_:)), "d"),
            item(String(localized: "Select All Occurrences"), #selector(AppDelegate.selectAllOccurrencesMenu(_:)), "g", [.control, .command]),
            .separator(),
            item(String(localized: "Add Caret Above"), #selector(AppDelegate.addCaretAboveMenu(_:)),
                 String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!), [.control, .shift]),
            item(String(localized: "Add Caret Below"), #selector(AppDelegate.addCaretBelowMenu(_:)),
                 String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), [.control, .shift]),
            // ⎋ while there are 2 or more carets (no key equivalent here: see MultiCaretEditing.swift).
            item(String(localized: "Single Caret"), #selector(AppDelegate.singleCaretMenu(_:))),
        ]),
        submenu(String(localized: "Line"), [
            item(String(localized: "Duplicate Line"), #selector(AppDelegate.duplicateLineMenu(_:)), "d", [.command, .shift]),
            item(String(localized: "Move Line Up"), #selector(AppDelegate.moveLineUpMenu(_:)),
                 String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!), [.control, .command]),
            item(String(localized: "Move Line Down"), #selector(AppDelegate.moveLineDownMenu(_:)),
                 String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), [.control, .command]),
            item(String(localized: "Delete Line"), #selector(AppDelegate.deleteLineMenu(_:)), "k", [.command, .shift]),
            // "Comment Selection", as in Xcode (it uncomments commented lines too); no "Toggle" titles (UX review #17).
            item(String(localized: "Comment Selection"), #selector(AppDelegate.toggleCommentMenu(_:)), "/"),
            .separator(),
            item(String(localized: "Indent"), #selector(AppDelegate.indentLinesMenu(_:)), "]"),
            item(String(localized: "Outdent"), #selector(AppDelegate.outdentLinesMenu(_:)), "["),
            .separator(),
            item(String(localized: "Keep Lines Matching…"), #selector(AppDelegate.keepLinesMatchingMenu(_:))),
            item(String(localized: "Delete Lines Matching…"), #selector(AppDelegate.deleteLinesMatchingMenu(_:))),
        ]),
        submenu(String(localized: "Bookmarks"), [
            // "Remove Bookmark" on a bookmarked line (EditingFeatures.validateEditingItem).
            item(String(localized: "Bookmark Line"), #selector(AppDelegate.toggleBookmarkMenu(_:)), f2, [.command]),
            item(String(localized: "Next Bookmark"), #selector(AppDelegate.nextBookmarkMenu(_:)), f2, []),
            item(String(localized: "Previous Bookmark"), #selector(AppDelegate.previousBookmarkMenu(_:)), f2, [.shift]),
            item(String(localized: "Bookmark All Matches"), #selector(AppDelegate.bookmarkAllMatchesMenu(_:)), f2, [.command, .option]),
            item(String(localized: "Clear Bookmarks"), #selector(AppDelegate.clearBookmarksMenu(_:)), f2, [.command, .shift]),
            .separator(),
            item(String(localized: "Copy Bookmarked Lines"), #selector(AppDelegate.copyBookmarkedLinesMenu(_:))),
            item(String(localized: "Delete Bookmarked Lines"), #selector(AppDelegate.deleteBookmarkedLinesMenu(_:))),
        ]),
        .separator(),
        submenu(String(localized: "Text Tools"), textToolItems()),
        .separator(),
        submenu(String(localized: "Indentation"), [
            item(String(localized: "Indent Using Spaces"), #selector(AppDelegate.indentUsingSpacesMenu(_:))),
            item(String(localized: "Indent Using Tabs"), #selector(AppDelegate.indentUsingTabsMenu(_:))),
            .separator(),
        ] + Indentation.widths.map {
            item(String(localized: "Tab Width: \($0)"), #selector(AppDelegate.tabWidthMenu(_:)), represented: $0)
        } + [
            .separator(),
            item(String(localized: "Convert Indentation to Spaces"), #selector(AppDelegate.convertIndentationToSpacesMenu(_:))),
            item(String(localized: "Convert Indentation to Tabs"), #selector(AppDelegate.convertIndentationToTabsMenu(_:))),
        ]),
        // Code folding (Folding.swift).
        foldingMenu(),
    ])
}

/// F2, as a key equivalent (bookmarks, as in Notepad++: F2 / ⇧F2 / ⌘F2).
let f2 = String(UnicodeScalar(UInt16(NSF2FunctionKey))!)

@MainActor
func buildMainMenu() -> NSMenu {
    let main = NSMenu()
    let app = "Owlink"

    // Filled by AppKit with the system's services (Cedric vends none).
    let services = submenu(String(localized: "Services"), [])
    main.addItem(submenu(app, [
        item(String(localized: "About Owlink"), #selector(AppDelegate.showAbout(_:)), ""),
        .separator(),
        item(String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), ","),
        .separator(),
        services,
        .separator(),
        item(String(localized: "Hide Owlink"), #selector(NSApplication.hide(_:)), "h"),
        item(String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
        item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))),
        .separator(),
        item(String(localized: "Quit Owlink"), #selector(NSApplication.terminate(_:)), "q"),
    ]))

    main.addItem(submenu(String(localized: "File"), [
        item(String(localized: "New Tab"), #selector(AppDelegate.newTab(_:)), "n"),
        // ⌘T opens a tab too (as in every tabbed Mac app), without a second "New Tab" in the menu.
        hiddenAlias(item(String(localized: "New Tab"), #selector(AppDelegate.newTab(_:)), "t")),
        item(String(localized: "New Window"), #selector(AppDelegate.newWindow(_:)), "n", [.command, .shift]),
        item(String(localized: "Open…"), #selector(AppDelegate.openDocument(_:)), "o"),
        // The folder's files and the document's headings, by fuzzy name (QuickOpenFiles.swift). ⌥⌘O:
        // ⌘P is Print… and ⇧⌘O Open Folder… (Xcode's Open Quickly key).
        item(String(localized: "Open Quickly…"), #selector(AppDelegate.openQuicklyMenu(_:)), "o", [.command, .option]),
        // Filled by AppDelegate.rebuildRecentMenu from the system recent-documents list.
        submenu(AppDelegate.recentMenuTitle, []),
        // The folder sidebar (FolderSidebar.swift).
        item(String(localized: "Open Folder…"), #selector(AppDelegate.openFolderMenu(_:)), "o", [.command, .shift]),
        // The tab's file: its folder in the sidebar, or in Finder.
        item(String(localized: "Open Enclosing Folder"), #selector(AppDelegate.openEnclosingFolderMenu(_:)), "o", [.command, .shift, .option]),
        item(String(localized: "Reveal in Finder"), #selector(AppDelegate.revealFileInFinderMenu(_:))),
        // A PDF tab's text in a new editable tab (PDFTab.swift).
        item(String(localized: "Open as Text"), #selector(PDFTabController.openAsText(_:))),
        // Viewer tabs: the file in its default app ("Open in Default App"; ViewerTabs.swift).
        item(String(localized: "Open in Default App"), #selector(ImageTabController.openInDefaultApp(_:))),
        .separator(),
        item(String(localized: "Close Tab"), #selector(NSWindow.performClose(_:)), "w"),
        item(String(localized: "Close Window"), #selector(AppDelegate.closeWindow(_:)), "w", [.command, .shift]),
        item(String(localized: "Reopen Closed Tab"), #selector(AppDelegate.reopenClosedTab(_:)), "t", [.command, .shift]),
        item(String(localized: "Save"), #selector(AppDelegate.saveDocument(_:)), "s"),
        item(String(localized: "Save As…"), #selector(AppDelegate.saveDocumentAs(_:)), "s", [.command, .shift]),
        item(String(localized: "Save All"), #selector(AppDelegate.saveAll(_:)), "s", [.command, .option]),
        item(String(localized: "Revert to Saved"), #selector(AppDelegate.revertToSaved(_:))),
        // Reloads the file as it grows, like tail -f (EditorTools.swift). In File, not View (0.4.1):
        // it changes where the tab's text comes from, not how the window looks.
        item(String(localized: "Follow File"), #selector(AppDelegate.followFileMenu(_:)), "t", [.command, .option]),
        .separator(),
        // Files in a git repository with a GitHub remote (GitIntegration.swift).
        item(String(localized: "Open on GitHub"), #selector(AppDelegate.openOnGitHubMenu(_:))),
        item(String(localized: "Copy GitHub Link"), #selector(AppDelegate.copyGitHubLinkMenu(_:))),
        // Two files side by side (CompareView.swift). In File, not View (0.4.1): it opens a comparison
        // of two documents (as FileMerge's File menu does); Next/Previous Difference act in its window.
        submenu(String(localized: "Compare"), [
            item(String(localized: "Compare With…"), #selector(AppDelegate.compareWithMenu(_:)), "c", [.command, .option]),
            item(String(localized: "Compare with Last Commit"), #selector(AppDelegate.compareWithLastCommitMenu(_:))),
            .separator(),
            item(String(localized: "Next Difference"), #selector(CompareWindowController.nextDifference(_:)),
                 String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!), [.command, .option]),
            item(String(localized: "Previous Difference"), #selector(CompareWindowController.previousDifference(_:)),
                 String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!), [.command, .option]),
        ]),
        .separator(),
        // No shortcut: ⇧⌘P is View › Command Palette… (0.4.0), as in VS Code and iA Writer.
        item(String(localized: "Page Setup…"), #selector(AppDelegate.pageSetup(_:))),
        item(String(localized: "Print…"), #selector(AppDelegate.printDocument(_:)), "p"),
        .separator(),
        item(String(localized: "Export as HTML…"), #selector(AppDelegate.exportHTMLMenu(_:))),
        item(String(localized: "Export as PDF…"), #selector(AppDelegate.exportPDFMenu(_:))),
    ]))

    let findItems = [
        item(String(localized: "Find…"), #selector(AppDelegate.showFind(_:)), "f"),
        item(String(localized: "Find and Replace…"), #selector(AppDelegate.showReplace(_:)), "f", [.command, .option]),
        item(String(localized: "Find Next"), #selector(AppDelegate.findNextMatch(_:)), "g"),
        item(String(localized: "Find Previous"), #selector(AppDelegate.findPreviousMatch(_:)), "g", [.command, .shift]),
        item(String(localized: "Use Selection for Find"), #selector(AppDelegate.useSelectionForFind(_:)), "e"),
        .separator(),
        item(String(localized: "Mark All"), #selector(AppDelegate.markAllMenu(_:)), "m", [.control, .command]),
        item(String(localized: "Clear Marks"), #selector(AppDelegate.clearMarksMenu(_:)), "m", [.control, .command, .shift]),
    ]
    main.addItem(submenu(String(localized: "Edit"), [
        item(String(localized: "Undo"), Selector(("undo:")), "z"),
        item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]),
        .separator(),
        item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"),
        item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"),
        item(String(localized: "Copy as HTML"), #selector(AppDelegate.copyAsHTMLMenu(_:))),
        item(String(localized: "Copy as Rich Text"), #selector(AppDelegate.copyAsRichTextMenu(_:))),
        item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
        item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"),
        .separator(),
        submenu(String(localized: "Find"), findItems),
        item(String(localized: "Find in Files…"), #selector(AppDelegate.findInFilesMenu(_:)), "f", [.command, .shift]),
        // Replace in Files (ReplaceInFiles+App.swift).
        item(String(localized: "Replace in Files…"), #selector(AppDelegate.replaceInFilesMenu(_:)), "f", [.command, .option, .shift]),
        item(String(localized: "Undo Replace in Files"), #selector(AppDelegate.undoReplaceInFilesMenu(_:))),
        item(String(localized: "Go to Line…"), #selector(AppDelegate.goToLine(_:)), "l"),
        item(String(localized: "Go to Heading…"), #selector(AppDelegate.goToHeadingMenu(_:)), "j", [.command, .shift]),
        .separator(),
        item(String(localized: "Auto-Close Brackets and Quotes"), #selector(AppDelegate.toggleAutoCloseBrackets(_:))),
        submenu(String(localized: "Spelling and Grammar"), [
            item(String(localized: "Show Spelling and Grammar"), #selector(NSText.showGuessPanel(_:)), ":"),
            item(String(localized: "Check Document Now"), #selector(AppDelegate.checkDocumentNow(_:)), ";"),
            item(String(localized: "Fix Typos…"), #selector(AppDelegate.fixTyposMenu(_:)), ";", [.command, .option]),
            item(String(localized: "Fix Grammar…"), #selector(AppDelegate.fixGrammarMenu(_:))),
            .separator(),
            item(String(localized: "Check Spelling While Typing"), #selector(AppDelegate.toggleSpellingWhileTyping(_:))),
            item(String(localized: "Check Grammar in Prose"), #selector(AppDelegate.toggleGrammar(_:))),
        ]),
    ]))

    main.addItem(textMenu())

    main.addItem(submenu(String(localized: "View"), [
        // Every menu command, searchable (CommandPalette.swift).
        item(String(localized: "Command Palette…"), #selector(AppDelegate.showCommandPalette(_:)), "p", [.command, .shift]),
        .separator(),
        // The preview bar's actions as menu items (0.2.1), enabled as the bar's buttons are.
        submenu(String(localized: "Preview"), [
            item(String(localized: "Show Preview"), #selector(AppDelegate.togglePreview(_:)), "p", [.command, .option]),
            // "Attach Preview" while detached (AppDelegate.validateMenuItem).
            item(String(localized: "Detach Preview"), #selector(AppDelegate.toggleDetachPreview(_:)), "p", [.command, .option, .shift]),
            .separator(),
            item(String(localized: "Back"), #selector(AppDelegate.previewBackMenu(_:))),
            item(String(localized: "Forward"), #selector(AppDelegate.previewForwardMenu(_:))),
            item(String(localized: "This Document"), #selector(AppDelegate.previewHomeMenu(_:))),
            item(String(localized: "Open in Browser"), #selector(AppDelegate.previewBrowserMenu(_:))),
            .separator(),
            item(String(localized: "Refresh Preview"), #selector(AppDelegate.refreshPreviewMenu(_:)), "r", [.command, .option]),
            item(String(localized: "Sync Scrolling"), #selector(AppDelegate.togglePreviewSyncMenu(_:))),
            item(String(localized: "Zoom In Preview"), #selector(AppDelegate.previewZoomInMenu(_:)), "=", [.command, .option]),
            item(String(localized: "Zoom Out Preview"), #selector(AppDelegate.previewZoomOutMenu(_:)), "-", [.command, .option]),
            item(String(localized: "Restore File Order"), #selector(AppDelegate.previewResetSortMenu(_:))),
            .separator(),
            item(String(localized: "Export as HTML…"), #selector(AppDelegate.exportHTMLMenu(_:))),
            item(String(localized: "Export as PDF…"), #selector(AppDelegate.exportPDFMenu(_:))),
            .separator(),
            item(String(localized: "Allow JavaScript in Preview"), #selector(AppDelegate.togglePreviewJavaScript(_:))),
            item(String(localized: "Allow Network in Preview"), #selector(AppDelegate.togglePreviewNetwork(_:))),
        ]),
        // A row of buttons above the text for file types that have a set (ContextBar.swift); on by default.
        // "Hide Context Bar" while shown (AppDelegate.validateMenuItem).
        item(String(localized: "Show Context Bar"), #selector(AppDelegate.toggleContextBarMenu(_:))),
        item(String(localized: "Show Outline"), #selector(AppDelegate.toggleOutlineMenu(_:)), "o", [.control, .command]),
        item(String(localized: "Show Folder Sidebar"), #selector(AppDelegate.toggleFolderSidebarMenu(_:)), "1", [.control, .command]),
        // The status bar word count's popover, from the keyboard and the palette (StatsPopover.swift).
        item(String(localized: "Show Statistics"), #selector(AppDelegate.showStatisticsMenu(_:))),
        // Typewriter scrolling and Focus, per tab, off by default (WritingMode.swift).
        writingModeMenu(),
        .separator(),
        // ⌥⌘Z, not bare ⌥Z: that types Ω (and other letters on other keyboards).
        item(String(localized: "Wrap Lines"), #selector(AppDelegate.toggleWrap(_:)), "z", [.command, .option]),
        // A centred column of text, per tab; off until chosen (ReadableWidthView.swift).
        item(String(localized: "Readable Width"), #selector(AppDelegate.toggleReadableWidthMenu(_:))),
        item(String(localized: "Show Invisibles"), #selector(AppDelegate.toggleInvisibles(_:)), "i", [.command, .option]),
        item(String(localized: "Show Line Numbers"), #selector(AppDelegate.toggleLineNumbers(_:))),
        item(String(localized: "Highlight Occurrences"), #selector(AppDelegate.toggleHighlightOccurrences(_:))),
        .separator(),
        // Two panes on one document (SplitEditor.swift).
    ] + splitEditorMenuItems() + [
        .separator(),
        item(String(localized: "Zoom In"), #selector(AppDelegate.zoomIn(_:)), "="),
        item(String(localized: "Zoom Out"), #selector(AppDelegate.zoomOut(_:)), "-"),
        item(String(localized: "Actual Size"), #selector(AppDelegate.zoomReset(_:)), "0"),
        // PDF tabs only (PDFTab.swift).
        item(String(localized: "Zoom to Fit"), #selector(PDFTabController.zoomToFit(_:)), "9"),
        item(String(localized: "Show Page Thumbnails"), #selector(PDFTabController.togglePDFThumbnails(_:)), "b", [.command, .option]),
        // The theme is in Settings only (0.2.1, settings-audit.md).
        .separator(),
        item(String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
    ]))

    main.addItem(submenu(String(localized: "Format"), [
        markdownMenu(),
        .separator(),
        submenu(String(localized: "Language"), Language.allCases.map {
            item($0.displayName, #selector(AppDelegate.pickLanguageMenu(_:)), represented: $0.rawValue)
        }),
        submenu(String(localized: "Encoding"), TextEncoding.allCases.map {
            item($0.displayName, #selector(AppDelegate.pickEncodingMenu(_:)), represented: $0.rawValue)
        }),
        submenu(String(localized: "Line Endings"), LineEnding.allCases.map {
            item($0.displayName, #selector(AppDelegate.pickLineEndingMenu(_:)), represented: $0.rawValue)
        }),
    ]))

    main.addItem(cedricMenu())

    let window = submenu(String(localized: "Window"), [
        item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"),
        item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))),
        item(String(localized: "Float on Top"), #selector(AppDelegate.toggleFloatOnTop(_:))),
        .separator(),
        item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))),
    ])
    main.addItem(window)
    NSApp.windowsMenu = window.submenu

    // Help: macOS adds its menu search field here (NSApp.helpMenu).
    let help = submenu(String(localized: "Help"), [
        item(String(localized: "Owlink Help"), #selector(AppDelegate.showHelp(_:)), "?"),
        item(String(localized: "Keyboard Shortcuts"), #selector(AppDelegate.showKeyboardShortcuts(_:))),
        .separator(),
        item(String(localized: "Owlink on GitHub"), #selector(AppDelegate.showGitHub(_:))),
        item(String(localized: "Report an Issue…"), #selector(AppDelegate.reportIssue(_:))),
    ])
    main.addItem(help)
    NSApp.helpMenu = help.submenu
    NSApp.servicesMenu = services.submenu
    return main
}

@MainActor
func runApp() {
    LaunchTrace.mark("main")
    let app = NSApplication.shared
    LaunchTrace.mark("nsapp")
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    LaunchTrace.mark("policy")
    app.mainMenu = buildMainMenu()
    LaunchTrace.mark("menu_built")
    // NSApp.delegate is weak: keep the delegate alive for the whole run
    // (a release build may otherwise free it right after the assignment).
    withExtendedLifetime(delegate) { app.run() }
}

MainActor.assumeIsolated { runApp() }
