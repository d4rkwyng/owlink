import AppKit
import CedricCore
import PDFKit
import WebKit

/// In-process checks of the Markdown preview and tools, run by
/// Scripts/tools-check.sh like the other DevChecks.
///
///   CEDRIC_CHECK=mdpreview|previewanchor|outline|mdexport
@MainActor
extension DevChecks {
    static func markdownPreviewCheck(_ name: String, _ app: AppDelegate) -> Bool {
        switch name {
        case "mdpreview": markdownPreview(app)
        case "previewanchor": previewAnchorCheck(app)
        case "outline": outlineCheck(app)
        case "mdexport": exportCheck(app)
        case "previewbar": previewBarCheck(app)
        case "mdsite": siteCheck(app)
        case "previewnav": previewNavigationDemo(app)
        case "mdfrontmatter": frontMatterCheck(app)
        default: return false
        }
        return true
    }

    static func previewNavigationDemo(_ app: AppDelegate) {
        guard let tab = app.tabs.first(where: { $0.doc.fileURL?.lastPathComponent == "Home.md" }) else {
            expect(false, "demo Home.md is open"); finish(); return
        }
        sized(tab)
        run([
            sync { focus(tab); if !tab.previewVisible { tab.togglePreview() } },
            waitForPreview(tab, contains: "A place for field notes", "demo home is shown"),
            { next in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    previewJS(tab, "Array.from(document.images).filter(i => i.complete && i.naturalWidth > 0).length") { value in
                        expect((value as? NSNumber)?.intValue == 3, "all three demo images load", "\(value ?? "nil")")
                        next()
                    }
                }
            },
            snapshot("home.png", window: tab.window),
            { next in previewJS(tab, "document.querySelector('a.wikilink').click(); 1") { _ in next() } },
            waitForPreview(tab, contains: "The other note", "demo wikilink opens in preview"),
            sync { expect(tab.preview?.canGoBack == true, "demo Back is enabled") },
            snapshot("local.png", window: tab.window),
            sync { tab.previewBarAction(.home) },
            waitForPreview(tab, contains: "A place for field notes", "demo Home returns to the editor document"),
            snapshot("returned-home.png", window: tab.window),
            sync { finish() },
        ])
    }

    /// The front matter block as the reader leaves it (Codex review of
    /// 0.5.2 (17), must-fix 3): opened, it stays open through edits (body
    /// swaps) and a whole-page reload, and the next document opens it from
    /// the preference; closed, the same. The preference is put back after.
    static func frontMatterCheck(_ app: AppDelegate) {
        let saved = UserDefaults.standard.object(forKey: FrontMatterDisclosure.preferenceKey)
        PreviewController.frontMatterExpanded = false
        let text = "---\ntitle: Owls of the World\nhero:\n  icon: owl.png\n---\n# Owls\n\nThey hunt at night.\n"
        let tab = app.open(write("owls.md", text))!
        sized(tab)
        let p = { tab.preview }
        var before = 0
        let state = "(() => { const d = document.querySelector('details.frontmatter'); return d ? String(d.open) : 'none' })()"
        func expectState(_ want: String, _ name: String, in t: EditorWindowController? = nil) -> (@escaping () -> Void) -> Void {
            { next in previewJS(t ?? tab, state) { v in expect(v as? String == want, name, "\(v ?? "nil")"); next() } }
        }
        func edit(_ s: String) -> (@escaping () -> Void) -> Void {
            sync {
                before = (p()?.bodySwaps ?? 0) + (p()?.pageLoads ?? 0)
                focus(tab)
                tab.textView.setSelectedRange(NSRange(location: (tab.text as NSString).length, length: 0))
                type(s)
            }
        }
        var second: EditorWindowController?
        var linker: EditorWindowController?
        run([
            sync { focus(tab); if !tab.previewVisible { tab.togglePreview() } },
            waitForPreview(tab, contains: "They hunt at night", "the preview shows the document"),
            expectState("false", "front matter collapsed by default"),
            { next in previewJS(tab, "document.querySelector('details.frontmatter').open = true; 1") { _ in next() } },
            edit("a"),
            waitForSwap(tab, "an edit renders", since: { before }),
            expectState("true", "an opened block stays open through an edit (body swap)"),
            sync { expect(PreviewController.frontMatterExpanded, "opening it is kept as the preference") },
            sync { p()?.forceReload(); before = (p()?.bodySwaps ?? 0) + (p()?.pageLoads ?? 0) },
            edit("b"),
            waitForSwap(tab, "a reload renders", since: { before }),
            waitForPreview(tab, contains: "night. ab", "the reloaded page shows the edits"),
            expectState("true", "an opened block stays open through a whole-page reload"),
            sync { second = app.open(write("barn.md", "---\ntitle: Barn owl\n---\n# Barn\n\nPale.\n")) },
            { next in
                guard let second else { expect(false, "second document opens"); next(); return }
                sized(second); focus(second)
                if !second.previewVisible { second.togglePreview() }
                next()
            },
            { next in
                guard let second else { next(); return }
                waitForPreview(second, contains: "Pale", "the second document's preview")(next)
            },
            { next in
                guard let second else { next(); return }
                expectState("true", "the next document opens the block from the preference", in: second)(next)
            },
            sync { focus(tab) },
            { next in previewJS(tab, "document.querySelector('details.frontmatter').open = false; 1") { _ in next() } },
            edit("c"),
            waitForSwap(tab, "an edit renders", since: { before }),
            expectState("false", "a closed block stays closed through an edit"),
            sync { expect(!PreviewController.frontMatterExpanded, "closing it is kept as the preference") },
            // Codex review of the 0.5.2 (17) fixes, should-fix: opened,
            // then the preview closed with no edit or refresh between.
            { next in previewJS(tab, "document.querySelector('details.frontmatter').open = true; 1") { _ in next() } },
            sync { focus(tab); tab.togglePreview() },
            until("closing the preview keeps the opened block as the preference", timeout: 5) { PreviewController.frontMatterExpanded },
            sync { tab.togglePreview() },
            waitForPreview(tab, contains: "They hunt at night", "the preview opens again"),
            expectState("true", "the reopened preview has the block open"),
            // Codex review round 2, should-fix: reopened at once, before
            // the close-time read has come back, the new preview still
            // shows the block as the reader left it.
            { next in previewJS(tab, "document.querySelector('details.frontmatter').open = false; 1") { _ in next() } },
            sync { focus(tab); tab.togglePreview(); tab.togglePreview() },
            waitForPreview(tab, contains: "They hunt at night", "the preview reopens at once"),
            expectState("false", "reopened at once, the closed block is still closed"),
            sync { expect(!PreviewController.frontMatterExpanded, "closing it at once is kept as the preference") },
            { next in previewJS(tab, "document.querySelector('details.frontmatter').open = true; 1") { _ in next() } },
            sync { focus(tab); tab.togglePreview(); tab.togglePreview() },
            waitForPreview(tab, contains: "They hunt at night", "the preview reopens at once again"),
            expectState("true", "reopened at once, the opened block is still open"),
            sync { expect(PreviewController.frontMatterExpanded, "opening it at once is kept as the preference") },
            // Codex review round 3, should-fix: the close-time read comes
            // back after its one-second timeout (held back 1.5 s), when
            // the reopened preview has already rendered with the old
            // preference: the late read still sets the block there.
            { next in previewJS(tab, "document.querySelector('details.frontmatter').open = false; 1") { _ in next() } },
            sync { PreviewController.closeReadDelayForChecks = 1.5; focus(tab); tab.togglePreview(); tab.togglePreview() },
            waitForPreview(tab, contains: "They hunt at night", "the preview reopens at once (a slow close-time read)"),
            // Codex b18 round 1, should-fix 2: the page shows the old state
            // while the read is out (the render didn't wait for it).
            expectState("true", "while the slow read is out, the reopened block shows the old state (open)"),
            untilState(tab, "false", "a close-time read that comes back late sets the reopened block closed", timeout: 5),
            sync { expect(!PreviewController.frontMatterExpanded, "the late read's closing is kept as the preference") },
            { next in previewJS(tab, "document.querySelector('details.frontmatter').open = true; 1") { _ in next() } },
            sync { focus(tab); tab.togglePreview(); tab.togglePreview() },
            waitForPreview(tab, contains: "They hunt at night", "the preview reopens at once again (a slow close-time read)"),
            expectState("false", "while the slow read is out, the reopened block shows the old state (closed)"),
            untilState(tab, "true", "a close-time read that comes back late sets the reopened block open", timeout: 5),
            sync { expect(PreviewController.frontMatterExpanded, "the late read's opening is kept as the preference") },
            sync { PreviewController.closeReadDelayForChecks = 0 },
            // Codex review round 3, should-fix 2: a slow close-time read in
            // this tab doesn't hold up a render in another tab (renders
            // used to wait for every close-time read, up to a second).
            { next in previewJS(tab, "document.querySelector('details.frontmatter').open = false; 1") { _ in next() } },
            sync { PreviewController.closeReadDelayForChecks = 1.5; focus(tab); tab.togglePreview() },
            { next in
                guard let second else { expect(false, "the second document is open"); next(); return }
                let start = (second.preview?.bodySwaps ?? 0) + (second.preview?.pageLoads ?? 0)
                let t0 = Date()
                second.renderPreview()
                @MainActor func poll() {
                    let n = (second.preview?.bodySwaps ?? 0) + (second.preview?.pageLoads ?? 0)
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    if n > start {
                        expect(ms < 500, "another tab's render isn't held up by a slow close-time read", "\(ms) ms")
                        next()
                    } else if ms > 3000 {
                        expect(false, "another tab's render isn't held up by a slow close-time read", "no render")
                        next()
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { MainActor.assumeIsolated { poll() } }
                    }
                }
                poll()
            },
            until("the slow close-time read still keeps the closed block", timeout: 4) { !PreviewController.frontMatterExpanded },
            sync { PreviewController.closeReadDelayForChecks = 0 },
            // Codex b18 round 1, must-fix 1: a change recorded in another
            // tab while this tab's slow read is out stays the preference,
            // and the read still sets this document's reopened block.
            sync { focus(tab); tab.togglePreview() },
            waitForPreview(tab, contains: "They hunt at night", "the preview opens (unrelated tab)"),
            expectState("false", "the preview opens with the block closed (unrelated tab)"),
            { next in previewJS(tab, "document.querySelector('details.frontmatter').open = true; 1") { _ in next() } },
            sync { PreviewController.closeReadDelayForChecks = 1.5; focus(tab); tab.togglePreview(); tab.togglePreview() },
            waitForPreview(tab, contains: "They hunt at night", "the preview reopens at once (unrelated tab)"),
            expectState("false", "while the read is out, the reopened block is still closed (unrelated tab)"),
            { next in
                guard let second else { next(); return }
                previewJS(second, "document.querySelector('details.frontmatter').open = false; 1") { _ in
                    before = (second.preview?.bodySwaps ?? 0) + (second.preview?.pageLoads ?? 0)
                    second.renderPreview()
                    waitForSwap(second, "the other tab renders", since: { before })(next)
                }
            },
            untilState(tab, "true", "a change in another tab doesn't stop the late read setting this document's block", timeout: 5),
            sync { expect(!PreviewController.frontMatterExpanded, "the other tab's newer change stays the preference") },
            sync { PreviewController.closeReadDelayForChecks = 0 },
            // Must-fix 2: closed, reopened and closed again before the
            // first read comes back, then reopened: the first read (the
            // only one that saw the change) still sets the block.
            sync { focus(tab); tab.togglePreview(); tab.togglePreview() },
            waitForPreview(tab, contains: "They hunt at night", "the preview reopens (two closes)"),
            expectState("false", "the block starts closed (two closes)"),
            { next in previewJS(tab, "document.querySelector('details.frontmatter').open = true; 1") { _ in next() } },
            sync { PreviewController.closeReadDelayForChecks = 1.5; focus(tab); tab.togglePreview(); tab.togglePreview() },
            waitForPreview(tab, contains: "They hunt at night", "the preview reopens at once (two closes)"),
            sync { focus(tab); tab.togglePreview(); tab.togglePreview() },
            waitForPreview(tab, contains: "They hunt at night", "the preview reopens a second time (two closes)"),
            expectState("false", "while the first read is out, the block is still closed (two closes)"),
            untilState(tab, "true", "a second close before the first read lands doesn't drop the reader's change", timeout: 5),
            until("and it is kept as the preference (two closes)", timeout: 3) { PreviewController.frontMatterExpanded },
            sync { PreviewController.closeReadDelayForChecks = 0 },
            // Must-fix 4: the reader clicks the block twice in the reopened
            // preview before the late read comes back: their choice stands.
            { next in previewJS(tab, "document.querySelector('details.frontmatter').open = false; 1") { _ in next() } },
            sync { PreviewController.closeReadDelayForChecks = 1.5; focus(tab); tab.togglePreview(); tab.togglePreview() },
            waitForPreview(tab, contains: "They hunt at night", "the preview reopens at once (double toggle)"),
            expectState("true", "while the read is out, the reopened block is still open (double toggle)"),
            { next in previewJS(tab, "const s = document.querySelector('details.frontmatter > summary'); s.click(); s.click(); 1") { _ in next() } },
            expectState("true", "two clicks leave the block open"),
            until("the late read comes back (double toggle)", timeout: 5) { !PreviewController.frontMatterExpanded },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } },
            expectState("true", "a late read doesn't undo the reader's two clicks"),
            sync { PreviewController.closeReadDelayForChecks = 0; focus(tab); tab.togglePreview() },
            until("closing keeps the reader's last choice (open) as the preference", timeout: 5) { PreviewController.frontMatterExpanded },
            // Must-fix 3: a read belongs to the page the preview shows. The
            // linked barn.md's state, read as A's preview closes while it
            // shows barn, isn't set on A's reopened page; A's own read isn't
            // set on barn shown in A's reopened preview.
            sync {
                linker = app.open(write("linker.md", "---\ntitle: Linker\n---\n# Linker\n\nSee [Barn](barn.md).\n"))
                if let l = linker { sized(l); focus(l); if !l.previewVisible { l.togglePreview() } }
            },
            { next in
                guard let l = linker else { expect(false, "the linking document opens"); next(); return }
                waitForPreview(l, contains: "See Barn", "the linking document's preview")(next)
            },
            { next in expectState("true", "the linking page opens the block from the preference", in: linker)(next) },
            { next in
                guard let l = linker else { next(); return }
                previewJS(l, "[...document.querySelectorAll('a')].find(a => a.textContent === 'Barn').click(); 1") { _ in
                    waitForPreview(l, contains: "Pale", "the preview shows the linked page")(next)
                }
            },
            { next in expectState("true", "the linked page opens the block from the preference", in: linker)(next) },
            { next in guard let l = linker else { next(); return }; previewJS(l, "document.querySelector('details.frontmatter').open = false; 1") { _ in next() } },
            sync { PreviewController.closeReadDelayForChecks = 1.5; if let l = linker { focus(l); l.togglePreview(); l.togglePreview() } },
            { next in guard let l = linker else { next(); return }; waitForPreview(l, contains: "See Barn", "reopened at once, the preview shows the linking page")(next) },
            { next in expectState("true", "while the linked page's read is out, the linking page's block is open", in: linker)(next) },
            until("the linked page's late read is kept as the preference", timeout: 5) { !PreviewController.frontMatterExpanded },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } },
            { next in expectState("true", "the linked page's late read isn't set on the linking document's page", in: linker)(next) },
            sync { PreviewController.closeReadDelayForChecks = 0; if let l = linker { focus(l); l.togglePreview(); l.togglePreview() } },
            { next in guard let l = linker else { next(); return }; waitForPreview(l, contains: "See Barn", "the linking page again")(next) },
            { next in expectState("false", "the linking page opens closed from the preference", in: linker)(next) },
            { next in guard let l = linker else { next(); return }; previewJS(l, "document.querySelector('details.frontmatter').open = true; 1") { _ in next() } },
            sync { PreviewController.closeReadDelayForChecks = 2.5; if let l = linker { focus(l); l.togglePreview(); l.togglePreview() } },
            { next in guard let l = linker else { next(); return }; waitForPreview(l, contains: "See Barn", "reopened at once, the linking page")(next) },
            { next in expectState("false", "while its read is out, the linking page's block is still closed", in: linker)(next) },
            { next in
                guard let l = linker else { next(); return }
                previewJS(l, "[...document.querySelectorAll('a')].find(a => a.textContent === 'Barn').click(); 1") { _ in
                    waitForPreview(l, contains: "Pale", "the reopened preview follows the link")(next)
                }
            },
            { next in expectState("false", "the linked page opens closed from the preference", in: linker)(next) },
            until("the linking page's late read is kept as the preference", timeout: 5) { PreviewController.frontMatterExpanded },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() } },
            { next in expectState("false", "the linking page's late read isn't set on the linked page its preview shows", in: linker)(next) },
            sync { PreviewController.closeReadDelayForChecks = 0 },
            sync {
                if let saved { UserDefaults.standard.set(saved, forKey: FrontMatterDisclosure.preferenceKey) }
                else { UserDefaults.standard.removeObject(forKey: FrontMatterDisclosure.preferenceKey) }
                finish()
            },
        ])
    }

    /// Waits (up to `timeout`) for the preview's front matter block to be
    /// `want` ("true", "false" or "none").
    static func untilState(_ tab: EditorWindowController, _ want: String, _ name: String, timeout: Double) -> (@escaping () -> Void) -> Void {
        { next in
            let deadline = Date().addingTimeInterval(timeout)
            let state = "(() => { const d = document.querySelector('details.frontmatter'); return d ? String(d.open) : 'none' })()"
            @MainActor func poll() {
                previewJS(tab, state) { v in
                    if v as? String == want { expect(true, name); next() }
                    else if Date() > deadline { expect(false, name, "\(v ?? "nil")"); next() }
                    else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } } }
                }
            }
            poll()
        }
    }

    /// Runs `code` in the preview, in Cedric's own content world (where
    /// its script lives), and hands over the result.
    static func previewJS(_ tab: EditorWindowController, _ code: String, _ then: @escaping @MainActor (Any?) -> Void) {
        guard let web = tab.preview?.webView else { then(nil); return }
        web.evaluateJavaScript(code, in: nil, in: .defaultClient) { result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let v): then(v)
                case .failure(let e): then("error: \(e)")
                }
            }
        }
    }

    /// The same, in the page's own world (what page JavaScript would see).
    static func pageJS(_ tab: EditorWindowController, _ code: String, _ then: @escaping @MainActor (Any?) -> Void) {
        guard let web = tab.preview?.webView else { then(nil); return }
        web.evaluateJavaScript(code) { v, _ in MainActor.assumeIsolated { then(v) } }
    }

    /// Waits (up to 5 s) for the preview to apply a render after the current one.
    static func waitForSwap(_ tab: EditorWindowController, _ name: String, since: @escaping () -> Int) -> (@escaping () -> Void) -> Void {
        { next in
            let start = since()
            let deadline = Date().addingTimeInterval(5)
            @MainActor func poll() {
                let n = (tab.preview?.bodySwaps ?? 0) + (tab.preview?.pageLoads ?? 0)
                if n > start { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { next() } }
                else if Date() > deadline { expect(false, name, "no render"); next() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { MainActor.assumeIsolated { poll() } } }
            }
            poll()
        }
    }

    /// The preview's quick-actions bar (PreviewBar): Markdown, the
    /// detached window, CSV; light and dark snapshots.
    static func previewBarCheck(_ app: AppDelegate) {
        var md = "# Bar\n\n"
        for k in 1...120 { md += "## Part \(k)\n\nLine \(k) of the bar check, long enough to fill the page.\n\n" }
        let tab = app.open(write("bar.md", md))!
        let csvTab = app.open(write("people.csv", "name,age\nzoe,31\namy,47\nbob,25\n"))!
        sized(tab); sized(csvTab)
        var bar: PreviewBar? { tab.previewPane?.bar }
        var webFrame = NSRect.zero, buttonFrames: [NSRect] = []
        func frames() -> [NSRect] { PreviewBarItem.allCases.compactMap { bar?.view($0) }.filter { !$0.isHidden }.map(\.frame) }
        func jsItem() -> NSMenuItem? { menuItem(action: #selector(AppDelegate.togglePreviewJavaScript(_:))) }
        func scrollY(_ then: @escaping @MainActor (Double) -> Void) { previewJS(tab, "window.scrollY") { then(($0 as? Double) ?? (($0 as? Int).map(Double.init) ?? -1)) } }
        var loadsBefore = 0
        run([
            sync {
                focus(tab)
                key("p", [.command, .option])
                expect(tab.previewVisible, "⌥⌘P shows the preview")
                let want: [PreviewBarItem] = [.back, .forward, .home, .refresh, .syncScroll, .zoomOut, .zoomIn, .export, .allowJavaScript, .allowNetwork, .detach]
                expect(bar?.state.items == want, "Markdown: the bar has its controls", "\(bar?.state.items ?? [])")
                for item in want {
                    guard let v = bar?.view(item) else { expect(false, "bar \(item)", "no view"); continue }
                    let tip = (v as? NSControl)?.toolTip ?? ""
                    let label = v.accessibilityLabel() ?? ""
                    let img = (v as? NSButton)?.image ?? (v as? NSPopUpButton)?.itemArray.first?.image
                    expect(!v.isHidden && !tip.isEmpty && !label.isEmpty && img != nil, "bar \(item.rawValue): shown, symbol, tooltip, VoiceOver label",
                           "hidden=\(v.isHidden) tip=\(tip) label=\(label) image=\(img != nil)")
                }
                expect(bar?.view(.sortReset)?.isHidden == true && bar?.rowLabel.isHidden == true, "no CSV controls on Markdown")
                let titles = bar?.exportButton.itemArray.dropFirst().map(\.title) ?? []
                expect(titles == ["Export as HTML…", "Export as PDF…"], "Export ▸ HTML / PDF", "\(titles)")
                expect(bar?.exportButton.itemArray.dropFirst().allSatisfy { $0.target === bar && $0.action != nil } == true, "the export items are wired")
                tab.window?.layoutIfNeeded()
                let h = tab.previewPane?.header.frame.height ?? 0
                expect(h == PreviewPane.headerHeight, "one compact row", "\(h)")
                expect(tab.previewPane?.header.appearance?.name == .darkAqua, "the bar follows the dark theme",
                       tab.previewPane?.header.appearance?.name.rawValue ?? "-")
            },
            waitForPreview(tab, contains: "Part 3", "the preview shows the document"),
            sync {
                // 0.2.1: the bar is on screen, and View › Preview has its actions.
                tab.window?.layoutIfNeeded()
                if let header = tab.previewPane?.header, let content = tab.window?.contentView {
                    let f = header.convert(header.bounds, to: content)
                    expect(!header.isHidden && header.window != nil && f.height >= PreviewPane.headerHeight - 1
                           && content.bounds.contains(f.insetBy(dx: 1, dy: 1)), "the preview bar is visible in the window", "\(f)")
                } else { expect(false, "the preview bar is visible in the window", "no header") }
                let view = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
                let preview = view?.items.first { $0.title == "Preview" }?.submenu
                let titles = preview?.items.map(\.title).filter { !$0.isEmpty } ?? []
                expect((titles.contains("Show Preview") || titles.contains("Hide Preview")) && ["Detach Preview", "Back", "Forward", "This Document", "Refresh Preview", "Sync Scrolling", "Zoom In Preview", "Zoom Out Preview",
                        "Restore File Order", "Export as HTML…", "Export as PDF…", "Allow JavaScript in Preview",
                        "Allow Network in Preview"].allSatisfy(titles.contains), "View › Preview lists the bar's actions", "\(titles)")
                @MainActor func enabled(_ sel: Selector) -> Bool { menuItem(action: sel).map { app.validateMenuItem($0) } ?? false }
                expect(enabled(#selector(AppDelegate.refreshPreviewMenu(_:))) && enabled(#selector(AppDelegate.togglePreviewSyncMenu(_:)))
                       && enabled(#selector(AppDelegate.previewZoomInMenu(_:))) && enabled(#selector(AppDelegate.exportHTMLMenu(_:))),
                       "…enabled like the bar's buttons")
                expect(!enabled(#selector(AppDelegate.previewResetSortMenu(_:))), "Restore File Order is off for Markdown (no such button)")
                let z = tab.preview?.webView.pageZoom ?? 0
                expect(choose(#selector(AppDelegate.previewZoomInMenu(_:))) && (tab.preview?.webView.pageZoom ?? 0) > z + 0.01,
                       "View › Preview › Zoom In Preview zooms the page", "\(z) → \(tab.preview?.webView.pageZoom ?? 0)")
                _ = choose(#selector(AppDelegate.previewZoomOutMenu(_:)))
                expect(abs((tab.preview?.webView.pageZoom ?? 0) - z) < 0.001, "…and Zoom Out Preview back")
            },
            snapshot("previewbar-dark.png"),
            sync {
                Settings.shared.themeOverride = .light
                NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
                tab.renderPreview()
                expect(tab.previewPane?.header.appearance?.name == .aqua, "the bar follows the light theme",
                       tab.previewPane?.header.appearance?.name.rawValue ?? "-")
            },
            snapshot("previewbar-light.png"),
            sync {
                webFrame = tab.previewPane?.renderer.view.frame ?? .zero
                buttonFrames = frames()
                guard let b = bar?.buttons[.allowJavaScript] else { return }
                press(b)
                expect(tab.previewAllowsJavaScript, "the bar's JavaScript toggle turns it on")
                expect(b.state == .on, "and shows it on")
                if let i = jsItem() { _ = app.validateMenuItem(i); expect(i.state == .on, "View › Allow JavaScript agrees") }
                expect(tab.previewPane?.renderer.view.frame == webFrame && frames() == buttonFrames, "no layout shift on toggling")
                app.togglePreviewJavaScript(nil)
                expect(!tab.previewAllowsJavaScript && b.state == .off, "the menu item still works and the bar follows it")
                if let n = bar?.buttons[.allowNetwork] {
                    press(n)
                    expect(tab.previewAllowsNetwork && n.state == .on, "the bar's Network toggle turns it on")
                    press(n)
                    expect(!tab.previewAllowsNetwork && n.state == .off, "and off")
                }
                expect(frames() == buttonFrames, "still no layout shift")
            },
            sync {
                guard let zin = bar?.buttons[.zoomIn], let zout = bar?.buttons[.zoomOut] else { return }
                press(zin)
                expect(abs((tab.preview?.webView.pageZoom ?? 0) - 1.1) < 0.001, "Zoom + zooms the page", "\(tab.preview?.webView.pageZoom ?? 0)")
                press(zout); press(zout)
                expect(abs((tab.preview?.webView.pageZoom ?? 0) - 0.9) < 0.001, "Zoom − zooms out", "\(tab.preview?.webView.pageZoom ?? 0)")
                expect(zin.toolTip?.contains("90%") == true, "the tooltip says the zoom", zin.toolTip ?? "-")
                press(zin)
                loadsBefore = tab.preview?.pageLoads ?? 0
                if let r = bar?.buttons[.refresh] { press(r) }
            },
            { next in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    expect((tab.preview?.pageLoads ?? 0) > loadsBefore, "Refresh reloads the whole page", "\(loadsBefore) → \(tab.preview?.pageLoads ?? 0)")
                    expect(abs((tab.preview?.webView.pageZoom ?? 0) - 1) < 0.001, "the zoom survives a reload")
                    next()
                }
            },
            sync {
                guard let s = bar?.buttons[.syncScroll] else { return }
                expect(s.state == .on && tab.previewSyncsScroll, "Sync Scrolling is on by default")
                press(s)
                expect(!tab.previewSyncsScroll && s.state == .off, "the bar turns Sync Scrolling off")
            },
            { next in
                scrollY { y0 in
                    tab.scrollToLine(200)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { scrollY { y in
                        expect(y == y0, "with sync off, the preview stays put", "scrollY \(y0) → \(y)")
                        if let s = bar?.buttons[.syncScroll] { press(s) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            scrollY { y in
                                expect(y > y0 + 200, "turned back on, it catches up with the text", "scrollY \(y0) → \(y)")
                                next()
                            }
                        }
                    } }
                }
            },
            sync {
                guard let d = bar?.buttons[.detach] else { return }
                press(d)
                expect(tab.previewDetached, "Detach on the bar")
                expect(d.accessibilityLabel() == "Attach", "it now says Attach", d.accessibilityLabel() ?? "-")
                expect(bar?.window === tab.previewWindow?.window, "the bar goes with it into its window")
            },
            { next in
                guard let w = tab.previewWindow?.window else { next(); return }
                snapshot("previewbar-detached-window-light.png", window: w)(next)
            },
            sync {
                guard let d = bar?.buttons[.detach] else { return }
                press(d)
                expect(!tab.previewDetached && tab.previewPane?.superview === tab.split, "Attach on the bar docks it again")
                Settings.shared.themeOverride = .dark
                NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
                focus(csvTab)
                key("p", [.command, .option])
            },
            { next in
                let deadline = Date().addingTimeInterval(5)
                @MainActor func poll() {
                    if (csvTab.previewPane?.renderer as? CSVPreview)?.renders ?? 0 > 0 || Date() > deadline { next() }
                    else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } } }
                }
                poll()
            },
            sync {
                let cbar = csvTab.previewPane?.bar
                expect(cbar?.state.items == [.rowCount, .sortReset, .refresh, .syncScroll, .zoomOut, .zoomIn, .detach],
                       "CSV: row count, Unsort, refresh, sync, zoom, detach", "\(cbar?.state.items ?? [])")
                expect(cbar?.rowLabel.stringValue == "3 rows" && cbar?.rowLabel.isHidden == false, "the row count", cbar?.rowLabel.stringValue ?? "-")
                csvTab.window?.layoutIfNeeded()
                if let l = cbar?.rowLabel {
                    expect(l.frame.width >= l.attributedStringValue.size().width, "the row count isn't cut short", "\(l.frame.width) < \(l.attributedStringValue.size().width)")
                }
                expect(cbar?.buttons[.allowJavaScript]?.isHidden == true && cbar?.exportButton.isHidden == true, "no web controls on CSV")
                expect(cbar?.buttons[.sortReset]?.isEnabled == false, "Unsort is off in file order")
                (csvTab.previewPane?.renderer as? CSVPreview)?.table.sortDescriptors = [NSSortDescriptor(key: "c1", ascending: true)]
            },
            snapshot("previewbar-csv-dark.png"),
            sync {
                let cbar = csvTab.previewPane?.bar
                let g = csvTab.previewPane?.renderer as? CSVPreview
                expect(g?.cell(row: 0, column: 0) == "bob", "sorted by age", g?.cell(row: 0, column: 0) ?? "-")
                expect(cbar?.buttons[.sortReset]?.isEnabled == true, "Unsort is on once sorted")
                if let u = cbar?.buttons[.sortReset] { press(u) }
            },
            sync {
                let cbar = csvTab.previewPane?.bar
                let g = csvTab.previewPane?.renderer as? CSVPreview
                expect(g?.isSorted == false && g?.cell(row: 0, column: 0) == "zoe", "Unsort puts it back in file order", g?.cell(row: 0, column: 0) ?? "-")
                expect(cbar?.buttons[.sortReset]?.isEnabled == false, "and Unsort is off again")
                let h0 = g?.table.rowHeight ?? 0
                if let z = cbar?.buttons[.zoomIn] { press(z); press(z) }
                expect(abs((g?.zoom ?? 0) - 1.25) < 0.001 && (g?.table.rowHeight ?? 0) > h0, "Zoom + enlarges the grid", "zoom=\(g?.zoom ?? 0) row=\(g?.table.rowHeight ?? 0)")
            },
        ], gap: 0.4)
    }

    /// A static site's page (Quartz, Hugo): `/images/…` root-absolute
    /// images in HTML and Markdown, and Obsidian wikilinks. The document
    /// is CEDRIC_SITE_DOC when set (a real site's index.md), else a small
    /// one made here, as `<site>/content/index.md`.
    static func siteCheck(_ app: AppDelegate) {
        var doc = ProcessInfo.processInfo.environment["CEDRIC_SITE_DOC"].map { URL(fileURLWithPath: $0) }
        if doc == nil {
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
            _ = write("site/static/images/dot.png", "")
            try? png.write(to: dir.appendingPathComponent("site/static/images/dot.png"))
            _ = write("site/content/blog/20261117-post.md", "# Post\n")
            doc = write("site/content/index.md", "---\ntitle: welcome\n---\n<img src=\"/images/dot.png\" alt=\"html\">\n\n![md](/images/dot.png)\n\n### [[20261117-post|The Post]]\n\n[[missing]] ==mark== #tag\n")
        }
        guard let doc, let tab = app.open(doc) else { expect(false, "opens the site page"); finish(); return }
        sized(tab)
        run([
            sync {
                focus(tab)
                key("p", [.command, .option])
                expect(tab.previewVisible, "⌥⌘P shows the preview")
            },
            waitForPreview(tab, contains: "welcome", "the preview shows the page"),
            { next in
                // Images load (or fail) a moment after the page.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { next() }
            },
            { next in
                previewJS(tab, "(() => { const i = [...document.images]; return i.length + ',' + i.filter(x => x.complete && x.naturalWidth > 0).length + ',' + i.filter(x => !(x.complete && x.naturalWidth > 0)).map(x => x.getAttribute('src')).join(' ') })()") { v in
                    let parts = (v as? String ?? "").split(separator: ",", maxSplits: 2).map(String.init)
                    expect(parts.count >= 2 && Int(parts[0]) ?? 0 > 0 && parts[0] == parts[1], "every site-root image loads", "\(v ?? "nil")")
                    next()
                }
            },
            { next in
                previewJS(tab, "document.querySelectorAll('a.wikilink[href]').length + ',' + document.body.innerText.includes('[[')") { v in
                    let parts = (v as? String ?? "").split(separator: ",").map(String.init)
                    expect(parts.count == 2 && Int(parts[0]) ?? 0 > 0 && parts[1] == "false", "wikilinks render as links, no raw [[", "\(v ?? "nil")")
                    next()
                }
            },
            snapshot("mdsite.png"),
            sync { finish() },
        ])
    }

    static func markdownPreview(_ app: AppDelegate) {
        var body = "# Notes\n\nFirst paragraph with a [link to other](other.md) and ![dot](dot.png).\n\n"
        // Security audit H2: links that must never launch anything.
        body += "[run](build.command) [app](Setup.app) [pkg](x.pkg) [hosts](cedric-doc://doc/etc/hosts) "
        body += "[term](file:///System/Applications/Utilities/Terminal.app) [smb](smb://attacker.invalid/share) "
        body += "[prefs](x-apple.systempreferences:com.apple.Security) [web](https://example.com/a?b=1)\n\n"
        body += "<script>document.title = 'page-script-ran'</script>\n\n<img src=\"nope.png\" onerror=\"document.title='handler-ran'\">\n\n"
        for k in 1...60 { body += "## Section \(k)\n\nParagraph \(k) with some *text* to fill the page out a little.\n\n- item a\n- item b\n\n" }
        // A 1x1 PNG beside the file (relative images load from the document's folder).
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        try? png.write(to: dir.appendingPathComponent("dot.png"))
        _ = write("other.md", "# Other\n\nthe other file\n")
        _ = write("build.command", "#!/bin/sh\ntouch \"$(dirname \"$0\")/launched\"\n")
        _ = write("Setup.app/Contents/MacOS/Setup", "#!/bin/sh\n")
        _ = write("x.pkg", "x")
        chmod(dir.appendingPathComponent("build.command").path, 0o755)
        let tab = app.open(write("notes.md", body))!
        sized(tab)
        let p = { tab.preview }
        var loadsBefore = 0, swapsBefore = 0
        var scrollY = 0.0
        run([
            sync {
                focus(tab)
                key("p", [.command, .option])
                expect(tab.previewVisible, "⌥⌘P shows the preview")
            },
            waitForPreview(tab, contains: "Paragraph 60", "the preview shows the document"),
            { next in
                previewJS(tab, "typeof window.__cedricPatch + ',' + typeof window.__cedricScrollTo") { v in
                    expect(v as? String == "function,function", "Cedric's script runs in its own world with page JavaScript off", "\(v ?? "nil")")
                    next()
                }
            },
            { next in
                pageJS(tab, "document.title + '|' + typeof window.__cedricPatch") { v in
                    expect(v as? String == "|undefined", "page scripts and handlers don't run, and the page can't see Cedric's script", "\(v ?? "nil")")
                    next()
                }
            },
            { next in
                previewJS(tab, "(() => { const i = document.querySelector('img[alt=dot]'); return i ? i.complete + ',' + i.naturalWidth : 'none' })()") { v in
                    expect(v as? String == "true,1", "a relative image loads from the document's folder", "\(v ?? "nil")")
                    next()
                }
            },
            { next in
                previewJS(tab, "document.documentElement.setAttribute('data-cedric-mark', '1'); window.__cedricQuietUntil = Date.now() + 500; window.scrollTo(0, 600); window.__cedricLineAt(window.scrollY + 8)") { v in
                    scrollY = (v as? NSNumber)?.doubleValue ?? -1
                    loadsBefore = p()?.pageLoads ?? 0
                    swapsBefore = p()?.bodySwaps ?? 0
                    next()
                }
            },
            sync {
                // An edit near the top: only that block is swapped in.
                let ns = tab.text as NSString
                tab.textView.setSelectedRange(NSRange(location: ns.range(of: "First paragraph").location, length: 0))
                type("Very ")
            },
            waitForSwap(tab, "typing renders the preview", since: { swapsBefore + loadsBefore }),
            waitForPreview(tab, contains: "Very First paragraph", "the edit shows in the preview"),
            { next in
                previewJS(tab, "document.documentElement.getAttribute('data-cedric-mark') + ',' + window.__cedricLineAt(window.scrollY + 8)") { v in
                    let parts = (v as? String ?? "").split(separator: ",")
                    expect(parts.first == "1", "the page isn't reloaded (no flash)", "\(v ?? "nil")")
                    let y = parts.count > 1 ? Double(parts[1]) ?? -1 : -1
                    expect(abs(y - scrollY) < 0.5, "the preview stays on the same text (an edit above doesn't move it)", "line before \(scrollY) after \(y)")
                    expect(p()?.pageLoads == loadsBefore && (p()?.bodySwaps ?? 0) > swapsBefore, "only the body is swapped",
                           "loads \(p()?.pageLoads ?? -1) swaps \(p()?.bodySwaps ?? -1)")
                    next()
                }
            },
            { next in
                previewJS(tab, "document.querySelectorAll('li[data-line]').length") { v in
                    expect(((v as? NSNumber)?.intValue ?? 0) >= 120, "list items carry their source lines", "\(v ?? "nil")")
                    next()
                }
            },
            // Editor → preview.
            // (Laid out whole first: an occluded window's text view doesn't grow by itself.)
            sync { if let tlm = tab.textView.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange); tlm.textViewportLayoutController.layoutViewport() }; tab.window?.displayIfNeeded(); tab.scrollToLine(200) },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() } },
            { next in
                let top = tab.topLine
                previewJS(tab, "window.__cedricLineAt(window.scrollY + 8)") { v in
                    let line = (v as? NSNumber)?.doubleValue ?? -1
                    expect(abs(line - Double(top)) <= 3, "scrolling the editor scrolls the preview to the same line", "editor \(top) preview \(line)")
                    next()
                }
            },
            // Preview → editor: a scroll the user makes in the preview.
            { next in
                previewJS(tab, "window.__cedricQuietUntil = 0; window.scrollTo(0, document.documentElement.scrollHeight / 4); window.__cedricLineAt(window.scrollY + 8)") { v in
                    let line = (v as? NSNumber)?.doubleValue ?? -1
                    // (An occluded window's page delivers its scroll events late: wait.)
                    let started = Date(), deadline = started.addingTimeInterval(6)
                    var nudged = false
                    @MainActor func poll() {
                        let top = tab.topLine
                        if abs(Double(top) - line) <= 3 {
                            expect(true, "scrolling the preview scrolls the editor to the same line")
                            print("check: note: the editor followed after \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
                            next()
                        } else if !nudged, Date().timeIntervalSince(started) > 1.5 {
                            // An occluded page gets no rendering updates, so WebKit
                            // may not deliver the scroll event at all: hand it over.
                            nudged = true
                            print("check: note: no scroll event from the occluded page after 1.5 s; dispatching one")
                            previewJS(tab, "window.dispatchEvent(new Event('scroll')); 1") { _ in poll() }
                        } else if Date() > deadline {
                            previewJS(tab, "window.__cedricLineAt(window.scrollY + 8) + ' setY=' + window.__cedricSetY + ' y=' + window.scrollY") { now in
                                expect(false, "scrolling the preview scrolls the editor to the same line", "preview \(line) editor \(top); preview now \(now ?? "-")")
                                next()
                            }
                        } else {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { poll() } }
                        }
                    }
                    poll()
                }
            },
            // A relative .md link stays in this preview and Home resumes live rendering.
            { next in
                let count = app.tabs.count
                tab.previewAllowsJavaScript = true
                previewJS(tab, "document.querySelector('a[href=\"other.md\"]').click(); 1") { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        tab.renderPreview()
                        previewJS(tab, "document.body.innerText") { text in
                            expect((text as? String)?.contains("the other file") == true, "relative Markdown opens in the preview and survives an editor render", "\(text ?? "nil")")
                            expect(app.tabs.count == count && tab.preview?.canGoBack == true, "no tab opened; Back is enabled")
                            expect(tab.previewAllowsJavaScript == false
                                   && tab.preview?.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript == false,
                                   "a navigated document does not inherit JavaScript trust")
                            tab.previewBarAction(.back)
                            expect(tab.previewAllowsJavaScript, "Back to the live document restores JavaScript")
                            tab.previewAllowsJavaScript = false
                            expect(tab.preview?.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript == false,
                                   "turning JavaScript off applies to the live document")
                            tab.previewBarAction(.forward)
                            expect(tab.previewAllowsJavaScript == false, "Forward to the linked document starts with JavaScript off")
                            tab.previewBarAction(.back)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                previewJS(tab, "document.body.innerText") { text in
                                    expect((text as? String)?.contains("Very First paragraph") == true, "Back returns to the live document", "\(text ?? "nil")")
                                    expect(tab.preview?.canGoForward == true, "Forward is enabled")
                                    tab.previewBarAction(.forward)
                                    tab.previewBarAction(.home)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                        previewJS(tab, "document.body.innerText") { text in
                                            expect((text as? String)?.contains("Very First paragraph") == true && tab.preview?.isHome == true,
                                                   "This Document restores the live preview", "\(text ?? "nil")")
                                            next()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            },
            // Hostile links: a script opens as text (never runs), an app and a
            // package are only revealed, files outside the folder only
            // revealed, other schemes ignored, a web link asks and never
            // loads in the preview (S1).
            { next in
                let tabsBefore = app.tabs.count
                PreviewLinkLog.revealed = []
                PreviewLinkLog.opened = []
                @MainActor func click(_ href: String, _ then: @escaping @MainActor () -> Void) {
                    previewJS(tab, "document.querySelector('a[href=\"\(href)\"]').click(); 1") { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { then() } }
                    }
                }
                @MainActor func action() -> PreviewLinkAction? { tab.preview?.lastLinkAction }
                @MainActor func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }
                click("build.command") {
                    let cmd = app.tabs.first { $0.doc.fileURL?.lastPathComponent == "build.command" }
                    if case .openInCedric = action() {
                        expect(cmd != nil, "a .command link opens as text in a Cedric tab", "\(app.tabs.count) tabs")
                    } else {
                        expect(action().map { if case .revealInFinder = $0 { return true } else { return false } } ?? false,
                               "a .command link is opened as text or only revealed", "\(String(describing: action()))")
                    }
                    cmd?.window?.performClose(nil)
                    focus(tab)
                    click("Setup.app") {
                        expect(PreviewLinkLog.revealed.last?.lastPathComponent == "Setup.app", "an .app link is revealed in Finder, not launched")
                        click("x.pkg") {
                            expect(PreviewLinkLog.revealed.last?.lastPathComponent == "x.pkg", "a .pkg link is revealed")
                            click("cedric-doc://doc/etc/hosts") {
                                expect(PreviewLinkLog.revealed.last?.path.hasSuffix("/etc/hosts") == true
                                       && !app.tabs.contains { $0.doc.fileURL?.lastPathComponent == "hosts" },
                                       "a file outside the folder is revealed, never read into a tab")
                                let before = PreviewLinkLog.revealed.count
                                click("file:///System/Applications/Utilities/Terminal.app") {
                                    // WebKit may refuse a file: navigation from the page outright (no
                                    // policy call): then nothing happens, which is as safe.
                                    let revealed = PreviewLinkLog.revealed.count > before
                                    expect(!revealed || PreviewLinkLog.revealed.last?.lastPathComponent == "Terminal.app",
                                           "a file: app link is revealed (or dropped by WebKit), not launched",
                                           revealed ? "revealed" : "dropped by WebKit")
                                    print("check: note: file: link \(revealed ? "revealed" : "dropped by WebKit")")
                                    click("smb://attacker.invalid/share") {
                                        expect(action() == .ignore("smb"), "an smb: link is ignored", "\(String(describing: action()))")
                                        expect(tab.noticeBar?.isHidden == false, "with a note in the tab")
                                        click("x-apple.systempreferences:com.apple.Security") {
                                            expect(action() == .ignore("x-apple.systempreferences"), "other schemes are ignored")
                                            let page = tab.preview?.webView.url
                                            click("https://example.com/a?b=1") {
                                                let web = URL(string: "https://example.com/a?b=1")!
                                                expect(action() == .confirmExternal(web), "a web link asks first (S1)", "\(String(describing: action()))")
                                                expect(tab.preview?.isHome == true && tab.preview?.webView.url == page && page?.scheme == "cedric-doc",
                                                       "and the preview does not navigate to it", "\(tab.preview?.webView.url?.absoluteString ?? "nil")")
                                                expect(tab.preview?.csp.contains("script-src 'none'") == true,
                                                       "local preview retains its strict CSP")
                                                expect(PreviewLinkLog.opened.isEmpty, "nothing opens before the answer")
                                                let sheet = tab.previewPane?.window?.attachedSheet
                                                let shown = sheet.flatMap { s in
                                                    s.contentView.flatMap { allViews($0) }?
                                                        .compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ") }
                                                expect(shown?.contains("https://example.com/a?b=1") == true,
                                                       "the prompt shows the whole URL", shown ?? "no sheet")
                                                if let sheet, let cancel = allViews(sheet.contentView!).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" }) {
                                                    cancel.performClick(nil)
                                                }
                                                tab.previewBarAction(.home)
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                                    MainActor.assumeIsolated {
                                                        expect(PreviewLinkLog.opened.isEmpty, "Cancel opens nothing")
                                                        expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("launched").path),
                                                               "nothing was launched")
                                                        expect(app.tabs.count == tabsBefore, "no stray tabs", "\(app.tabs.count) vs \(tabsBefore)")
                                                        tab.noticeBar?.isHidden = true
                                                        next()
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            },
            // Detached: still swapped in place.
            sync {
                focus(tab)
                key("p", [.command, .option, .shift])
                expect(tab.previewDetached, "the preview detaches")
                loadsBefore = p()?.pageLoads ?? 0
                swapsBefore = p()?.bodySwaps ?? 0
                tab.textView.setSelectedRange(NSRange(location: (tab.text as NSString).length, length: 0))
                type("detached edit")
            },
            waitForPreview(tab, contains: "detached edit", "typing updates the detached preview"),
            sync {
                expect(p()?.pageLoads == loadsBefore && (p()?.bodySwaps ?? 0) > swapsBefore, "the detached preview swaps the body too",
                       "loads \(p()?.pageLoads ?? -1) swaps \(p()?.bodySwaps ?? -1)")
                key("p", [.command, .option, .shift])
                expect(!tab.previewDetached && tab.previewVisible, "and docks again")
            },
            { next in perfBigMarkdown(app, tab, next) },
            sync { for t in app.tabs { t.doc.markSaved() } },
        ])
    }

    /// Waits (polling, up to `seconds`) until the element with `id` is in
    /// the preview's view, scrolled to (its top inside the viewport and the
    /// page scrolled down: every target here starts well below the fold),
    /// and `when` holds. Then, a moment later, that it is still there (no
    /// late scroll event or editor sync moved it away).
    static func waitForAnchor(_ tab: EditorWindowController, id: String, _ name: String, seconds: Double = 5,
                              when: @escaping @MainActor () -> Bool = { true }) -> (@escaping () -> Void) -> Void {
        { next in
            let js = "(() => { const e = document.getElementById('\(id)'); if (!e) return 'none|-|' + Math.round(window.scrollY);"
                + " const t = e.getBoundingClientRect().top;"
                + " return ((t > -4 && t < window.innerHeight - 30 && window.scrollY > 40) ? 'in' : 'out') + '|' + Math.round(t) + '|' + Math.round(window.scrollY) })()"
            let deadline = Date().addingTimeInterval(seconds)
            @MainActor func poll() {
                previewJS(tab, js) { v in
                    let r = v as? String ?? "\(v ?? "nil")"
                    if when(), r.hasPrefix("in|") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            previewJS(tab, js) { again in
                                let r2 = again as? String ?? "nil"
                                expect(r2.hasPrefix("in|"), name, "first \(r), then \(r2)")
                                next()
                            }
                        }
                    } else if Date() > deadline {
                        expect(false, name, "heading #\(id): \(r) (in|top|scrollY); condition \(when())")
                        next()
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { poll() } }
                    }
                }
            }
            poll()
        }
    }

    /// Links to headings: a same-page `#anchor` (plain, by heading text, and
    /// ⌘-click) scrolls the live document in place; `other.md#part`, a
    /// heading-text fragment, a `[[other#Part]]` wikilink and `page.html#sec`
    /// open in the preview at that heading, and Back/Forward come back to it.
    /// How `webPrompt` answers: the Cancel button, or the Return or Escape key.
    enum PromptAnswer { case cancelButton, returnKey, escapeKey }

    /// Waits (up to 3 s) for the external-link prompt on the tab's preview,
    /// expects it to show `url` whole with Cancel as the default button
    /// (Return) and Open with no key, and answers Cancel (by button or key).
    static func webPrompt(_ tab: EditorWindowController, _ url: String, _ name: String,
                          answer: PromptAnswer = .cancelButton, contains: [String] = []) -> (@escaping () -> Void) -> Void {
        { next in
            @MainActor func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }
            let window = tab.previewPane?.window ?? tab.window
            let deadline = Date().addingTimeInterval(3)
            @MainActor func poll() {
                guard let sheet = window?.attachedSheet else {
                    if Date() < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { poll() } }; return }
                    expect(false, name, "no prompt")
                    next(); return
                }
                let views = sheet.contentView.map(allViews) ?? []
                let shown = views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
                expect(shown.contains("Open this link?") && shown.contains(url) && contains.allSatisfy(shown.contains), name, shown)
                let buttons = views.compactMap { $0 as? NSButton }
                // NSAlert hands Return to the window's default button cell.
                let defaultTitle = (sheet.defaultButtonCell as? NSButtonCell)?.title
                let keys = buttons.filter { !$0.title.isEmpty }.map { "\($0.title)=\($0.keyEquivalent.unicodeScalars.map { String($0.value, radix: 16) })" }
                expect(defaultTitle == "Cancel" && buttons.first { $0.title == "Open" }?.keyEquivalent == "",
                       "Cancel is the prompt's default button (Return); Open has no key",
                       "default \(defaultTitle ?? "none"); " + keys.joined(separator: " "))
                let openedBefore = PreviewLinkLog.opened.count
                func key(_ chars: String, _ code: UInt16) -> NSEvent? {
                    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: sheet.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
                }
                switch answer {
                case .cancelButton: buttons.first { $0.title == "Cancel" }?.performClick(nil)
                case .returnKey:
                    // A key Return reaches the default button only in the key
                    // window; when Owlink isn't the active app, press the
                    // default button instead (what Return does) and say so.
                    if sheet.isKeyWindow, let e = key("\r", 36) { NSApp.postEvent(e, atStart: false) }
                    else {
                        print("check: note: the prompt isn't the key window (Owlink not active): Return pressed as the default button")
                        sheet.defaultButtonCell?.performClick(nil)
                    }
                case .escapeKey: if let e = key("\u{1b}", 53) { NSApp.postEvent(e, atStart: false) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    MainActor.assumeIsolated {
                        if answer != .cancelButton {
                            expect(window?.attachedSheet == nil && PreviewLinkLog.opened.count == openedBefore,
                                   answer == .returnKey ? "Return answers Cancel: nothing opens" : "Escape answers Cancel: nothing opens",
                                   "sheet \(window?.attachedSheet != nil) opened \(PreviewLinkLog.opened.map(\.absoluteString))")
                        }
                        next()
                    }
                }
            }
            poll()
        }
    }

    static func previewAnchorCheck(_ app: AppDelegate) {
        var filler = ""
        for k in 1...40 { filler += "Filler paragraph \(k) with enough words in it to take up a line or two of the preview.\n\n" }
        _ = write("anchors/other.md", "# Other\n\n" + filler + "## Part\n\nthe part of the other file\n\n" + filler)
        var html = "<!doctype html><html><body><h1>Page</h1>"
        for k in 1...40 { html += "<p>html filler \(k), a line or two of words to fill the page out.</p>" }
        html += "<h2 id=\"sec\">Sec</h2><p>the html section</p>"
        // S1: a meta refresh to a web page must not load it in the preview.
        html += "<meta http-equiv=\"refresh\" content=\"0;url=https://example.invalid/refresh\">"
        for k in 1...40 { html += "<p>more html \(k)</p>" }
        _ = write("anchors/page.html", html + "</body></html>")
        // A symbolic link to a document in a subfolder: the page's relative
        // image loads from the folder the file is really in.
        _ = write("anchors/real/doc.md", "# Real\n\nthe real doc ![dot](dot.png)\n")
        try? Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
            .write(to: dir.appendingPathComponent("anchors/real/dot.png"))
        try? FileManager.default.createSymbolicLink(atPath: dir.appendingPathComponent("anchors/alias.md").path, withDestinationPath: "real/doc.md")
        var src = "# Anchors\n\n[other part](other.md#part) [text part](other.md#Part) [[other#Part|wiki part]] [html part](page.html#sec) [alias](alias.md)"
        src += " [jump](#unique-section) [jump text](#Unique%20Section)"
        // S1: web links, plain and target=_blank.
        src += " [web](https://example.invalid/s1?q=1) <a href=\"https://example.invalid/blank\" target=\"_blank\">blank web</a>"
        // A user name dressed as a site: the prompt names the real one.
        src += " [spoof](https://www.apple.com%2Fsignin@evil.example/)\n\n" + filler + "## Unique Section\n\nthe unique section\n\n" + filler
        let tab = app.open(write("anchors/notes.md", src))!
        sized(tab)
        let tabs = app.tabs.count
        let p = { tab.preview }
        @MainActor func onSource() -> Bool { tab.doc.fileURL?.lastPathComponent == "notes.md" && tab.text.hasPrefix("# Anchors") }
        @MainActor func noTab() -> Bool { app.tabs.count == tabs }
        var loadsBefore = 0
        func click(_ text: String, command: Bool = false) -> (@escaping () -> Void) -> Void {
            { next in
                let fire = command
                    ? "a.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, metaKey: true}))"
                    : "a.click()"
                previewJS(tab, "(() => { const a = [...document.querySelectorAll('a')].find(a => a.textContent === '\(text)'); if (!a) return 'no link'; \(fire); return a.getAttribute('href') })()") { v in
                    print("check: note: clicked \(text) → \(v ?? "nil")")
                    next()
                }
            }
        }
        let toTop: (@escaping () -> Void) -> Void = { next in
            previewJS(tab, "window.__cedricQuietUntil = Date.now() + 500; window.scrollTo(0, 0); window.scrollY") { _ in next() }
        }
        var livePage: URL?
        var promptsBefore = 0, droppedBefore = 0
        var blank: EditorWindowController?
        // S1: the preview stays on the live document; no web page, no tab, nothing opened.
        @MainActor func stayed(_ name: String) {
            expect(p()?.isHome == true && p()?.webView.url == livePage && livePage?.scheme == "cedric-doc" && noTab()
                   && PreviewLinkLog.opened.isEmpty && p()?.webView.isLoading == false,
                   name, "\(p()?.webView.url?.absoluteString ?? "nil") loading \(p()?.webView.isLoading ?? false)")
        }
        let home: (@escaping () -> Void) -> Void = { next in
            tab.previewBarAction(.home)
            waitForPreview(tab, contains: "jump text", "This Document returns to the live document")(next)
        }
        run([
            sync { focus(tab); if !tab.previewVisible { tab.togglePreview() } },
            waitForPreview(tab, contains: "the unique section", "the preview shows the document"),
            // Same page: stays on the live document, no tab, heading in view.
            click("jump"),
            waitForAnchor(tab, id: "unique-section", "a same-page #anchor scrolls the live document to the heading",
                          when: { p()?.isHome == true && noTab() }),
            sync {
                expect(p()?.isHome == true && noTab() && onSource(), "and stays on the live document, no tab opened")
                expect(p()?.lastAnchor?.found == true, "Cedric found the anchor", "\(String(describing: p()?.lastAnchor))")
            },
            toTop,
            click("jump text"),
            waitForAnchor(tab, id: "unique-section", "a same-page fragment by heading text finds the heading's slug",
                          when: { p()?.isHome == true && noTab() }),
            toTop,
            click("jump", command: true),
            waitForAnchor(tab, id: "unique-section", "⌘-click on a same-page #anchor stays in the page",
                          when: { p()?.isHome == true && noTab() }),
            sync { expect(p()?.isHome == true && noTab() && PreviewLinkLog.revealed.isEmpty, "and reveals or opens nothing") },
            toTop,
            // With page JavaScript and Network on for the live document,
            // the page's own world can't reach Cedric's scroll script or
            // its message handler (they live in the app's content world).
            sync { loadsBefore = (p()?.pageLoads ?? 0) + (p()?.bodySwaps ?? 0); tab.previewAllowsJavaScript = true; tab.previewAllowsNetwork = true },
            waitForSwap(tab, "the live document re-renders with JavaScript on", since: { loadsBefore }),
            waitForPreview(tab, contains: "jump text", "and shows the document"),
            { next in
                previewJS(tab, "typeof window.__cedricScrollToAnchor + ',' + typeof window.webkit?.messageHandlers?.cedricScroll") { own in
                    pageJS(tab, "typeof window.__cedricScrollToAnchor + ',' + typeof window.webkit?.messageHandlers?.cedricScroll") { page in
                        expect(own as? String == "function,object", "Cedric's world has the anchor script and the cedricScroll handler", "\(own ?? "nil")")
                        expect(page as? String == "undefined,undefined",
                               "page JavaScript can't see __cedricScrollToAnchor or the cedricScroll handler", "\(page ?? "nil")")
                        next()
                    }
                }
            },
            // S1: with page JavaScript and Network on, a web link still never
            // loads in the preview: a click asks (whole URL), Cancel opens
            // nothing; script, forms and new windows go nowhere.
            sync { livePage = p()?.webView.url; PreviewLinkLog.opened = [] },
            click("web"),
            webPrompt(tab, "https://example.invalid/s1?q=1", "a plain click on a web link asks first, showing the whole URL"),
            sync {
                expect(p()?.lastLinkAction == .confirmExternal(URL(string: "https://example.invalid/s1?q=1")!), "routed as an external link",
                       "\(String(describing: p()?.lastLinkAction))")
                stayed("the preview did not load the web page; Cancel opened nothing")
            },
            // Page script clicking the declined link over and over: no prompt comes back.
            { next in
                promptsBefore = LinkPrompt.shown
                pageJS(tab, "const w = [...document.querySelectorAll('a')].find(a => a.textContent === 'web'); for (let i = 0; i < 5; i++) w.click(); 1") { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { next() }
                }
            },
            sync {
                expect(LinkPrompt.shown == promptsBefore && (tab.previewPane?.window ?? tab.window)?.attachedSheet == nil && (p()?.droppedExternal ?? 0) >= 1,
                       "with JavaScript on, script re-clicking a declined web link doesn't ask again",
                       "shown \(LinkPrompt.shown - promptsBefore) dropped \(p()?.droppedExternal ?? 0)")
                stayed("and nothing loads")
                promptsBefore = LinkPrompt.shown
                droppedBefore = LinkPrompt.dropped
            },
            // Another web link from the same page load: dropped too (a script
            // can't loop the prompt by changing the URL).
            { next in
                pageJS(tab, "const b = [...document.querySelectorAll('a')].find(a => a.textContent === 'blank web'); b.click(); 1") { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { next() }
                }
            },
            sync {
                expect(LinkPrompt.shown == promptsBefore && (tab.previewPane?.window ?? tab.window)?.attachedSheet == nil && (p()?.droppedExternal ?? 0) >= 2,
                       "after a Cancel with JavaScript on, another web link from the same page load doesn't ask either",
                       "shown \(LinkPrompt.shown - promptsBefore) dropped \(p()?.droppedExternal ?? 0)")
                stayed("and nothing loads")
                loadsBefore = p()?.pageLoads ?? 0
                tab.previewBarAction(.refresh)
            },
            // A new page load asks again.
            { next in
                let deadline = Date().addingTimeInterval(5)
                @MainActor func poll() {
                    if (p()?.pageLoads ?? 0) > loadsBefore, p()?.webView.isLoading == false {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() }
                    } else if Date() > deadline { expect(false, "Refresh reloads the page", "\(loadsBefore) → \(p()?.pageLoads ?? 0)"); next() }
                    else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } } }
                }
                poll()
            },
            waitForPreview(tab, contains: "jump text", "the reloaded document is shown"),
            sync { livePage = p()?.webView.url; promptsBefore = LinkPrompt.shown; droppedBefore = LinkPrompt.dropped },
            // Another web link, clicked three times at once by script: one prompt, never stacked.
            { next in
                pageJS(tab, "const b = [...document.querySelectorAll('a')].find(a => a.textContent === 'blank web'); b.click(); b.click(); b.click(); 1") { _ in next() }
            },
            webPrompt(tab, "https://example.invalid/blank", "after a reload, a target=_blank web link asks again", answer: .returnKey),
            sync {
                expect(LinkPrompt.shown == promptsBefore + 1 && LinkPrompt.dropped >= droppedBefore + 1, "one prompt at a time: the repeats are dropped, not stacked",
                       "shown \(LinkPrompt.shown - promptsBefore) dropped \(LinkPrompt.dropped - droppedBefore)")
                stayed("and the preview did not load it either")
                loadsBefore = p()?.pageLoads ?? 0
                tab.previewBarAction(.refresh)
            },
            { next in
                let deadline = Date().addingTimeInterval(5)
                @MainActor func poll() {
                    if (p()?.pageLoads ?? 0) > loadsBefore, p()?.webView.isLoading == false {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() }
                    } else if Date() > deadline { expect(false, "Refresh reloads the page again", "\(loadsBefore) → \(p()?.pageLoads ?? 0)"); next() }
                    else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } } }
                }
                poll()
            },
            waitForPreview(tab, contains: "jump text", "the reloaded document is shown again"),
            sync { livePage = p()?.webView.url },
            click("spoof"),
            webPrompt(tab, "https://www.apple.com%2Fsignin@evil.example/",
                      "a click asks again on the next load; a user name before @ is called out and the real site shown on its own line",
                      answer: .escapeKey, contains: ["Site: evil.example", "user name (“www.apple.com/signin”)", "This link goes to evil.example."]),
            sync { stayed("Escape opened nothing") },
            { next in pageJS(tab, "location.href = 'https://example.invalid/script'; 1") { _ in next() } },
            { next in
                pageJS(tab, "window.open('https://example.invalid/popup'); const f = document.createElement('form'); f.action = 'https://example.invalid/form'; f.method = 'get'; document.body.appendChild(f); f.submit(); 1") { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { next() }
                }
            },
            sync {
                stayed("page script's location =, window.open and a form submit don't leave the document")
                expect((tab.previewPane?.window ?? tab.window)?.attachedSheet == nil, "and ask nothing (only a click asks)")
            },
            waitForPreview(tab, contains: "jump text", "the live document is still shown"),
            // Another document's heading.
            click("other part"),
            waitForAnchor(tab, id: "part", "other.md#part opens in the preview at the heading",
                          when: { p()?.isHome == false && p()?.navigationTitle == "other.md" }),
            sync {
                expect(noTab() && onSource(), "no tab opened; the editor stays on the source document", "\(app.tabs.count) tabs, \(tab.doc.fileURL?.lastPathComponent ?? "-")")
                expect(p()?.canGoBack == true && tab.previewAllowsJavaScript == false && tab.previewAllowsNetwork == false,
                       "Back is enabled; no JavaScript or Network trust carried over",
                       "JS \(tab.previewAllowsJavaScript) Network \(tab.previewAllowsNetwork)")
                expect(p()?.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript == false,
                       "the linked document's page runs with JavaScript off")
                // The live document reloads from disk while the preview is
                // away from it: Back must not turn JavaScript/Network on
                // again for the new content.
                tab.reloadFromDisk()
                tab.previewBarAction(.back)
                expect(p()?.isHome == true && tab.previewAllowsJavaScript == false && tab.previewAllowsNetwork == false,
                       "after a reload from disk while navigated away, Back keeps JavaScript and Network off",
                       "JS \(tab.previewAllowsJavaScript) Network \(tab.previewAllowsNetwork)")
                tab.previewBarAction(.forward)
                tab.previewBarAction(.home)
                expect(p()?.isHome == true && tab.previewAllowsJavaScript == false && tab.previewAllowsNetwork == false,
                       "and This Document keeps them off too")
                tab.previewBarAction(.back)
                tab.previewBarAction(.back)
            },
            waitForPreview(tab, contains: "jump text", "Back returns to the source document"),
            sync { expect(p()?.isHome == true && p()?.canGoForward == true, "on the live document, Forward enabled"); tab.previewBarAction(.forward) },
            waitForAnchor(tab, id: "part", "Forward returns to the linked document at the heading again",
                          when: { p()?.isHome == false && p()?.navigationTitle == "other.md" }),
            home,
            click("text part"),
            waitForAnchor(tab, id: "part", "other.md#Part (heading text) opens at the heading",
                          when: { p()?.isHome == false && noTab() }),
            home,
            { next in
                previewJS(tab, "document.querySelector('a.wikilink').getAttribute('href')") { v in
                    expect((v as? String)?.hasSuffix("/anchors/other.md#part") == true, "[[other#Part]] links to the heading's slug", "\(v ?? "nil")")
                    next()
                }
            },
            click("wiki part"),
            waitForAnchor(tab, id: "part", "a [[other#Part]] wikilink opens at the heading",
                          when: { p()?.isHome == false && noTab() }),
            home,
            click("html part"),
            waitForAnchor(tab, id: "sec", "page.html#sec opens in the preview at the element",
                          when: { p()?.isHome == false && p()?.navigationTitle == "page.html" && noTab() }),
            sync { expect(onSource() && PreviewLinkLog.revealed.isEmpty && PreviewLinkLog.opened.isEmpty, "nothing revealed or opened outside the preview") },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 1) { next() } },
            sync {
                let url = p()?.webView.url
                expect(p()?.navigationTitle == "page.html" && url?.scheme == "cedric-doc" && url?.absoluteString.hasSuffix("/anchors/") == true
                       && p()?.webView.isLoading == false,
                       "page.html's meta refresh to a web page does not load it (S1)", url?.absoluteString ?? "nil")
            },
            home,
            click("alias"),
            waitForPreview(tab, contains: "the real doc", "a symbolic link to a document opens in the preview"),
            { next in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    previewJS(tab, "location.href + '|' + [...document.images].filter(i => i.complete && i.naturalWidth > 0).length") { v in
                        let parts = (v as? String ?? "").split(separator: "|").map(String.init)
                        expect(parts.count == 2 && parts[0].hasSuffix("/anchors/real/") && parts[1] == "1",
                               "its page is based in the linked file's own folder, and its relative image loads", "\(v ?? "nil")")
                        next()
                    }
                }
            },
            home,
            // An untitled document's preview is at about:blank (security read
            // NIT 1): a click on #far, or an href written about:blank%23far
            // (what macOS 15 hands over for #far), scrolls in place; WebKit's
            // navigation is cancelled, so the page never leaves about:blank.
            sync {
                app.newTab(nil)
                guard let t = app.tabs.last else { return }
                blank = t
                sized(t)
                t.setText("# Blank\n\n[far](#far-away) <a href=\"about:blank%23far-away\">lit</a>\n\n" + filler + "## Far Away\n\nthe far section\n\n" + filler)
                t.setLanguage(.markdown)
                focus(t)
                if !t.previewVisible { t.togglePreview() }
            },
            { next in if let b = blank { waitForPreview(b, contains: "the far section", "an untitled document's preview shows it")(next) } else { expect(false, "untitled tab"); next() } },
        ] + ["far", "lit"].flatMap { (text: String) -> [(@escaping () -> Void) -> Void] in [
            { next in
                guard let b = blank else { next(); return }
                expect(b.preview?.webView.url?.absoluteString == "about:blank", "\(text): the page is at about:blank", b.preview?.webView.url?.absoluteString ?? "nil")
                previewJS(b, "window.__cedricQuietUntil = Date.now() + 500; window.scrollTo(0, 0); window.scrollY") { _ in
                    previewJS(b, "(() => { const a = [...document.querySelectorAll('a')].find(a => a.textContent === '\(text)'); if (!a) return 'no link'; a.click(); return a.getAttribute('href') })()") { v in
                        print("check: note: clicked \(text) → \(v ?? "nil")")
                        next()
                    }
                }
            },
            { next in
                guard let b = blank else { next(); return }
                waitForAnchor(b, id: "far-away", "on about:blank, a click on \(text) scrolls the page (not routed)",
                              when: { b.preview?.isHome == true && b.preview?.lastAnchor?.found == true })(next)
            },
            { next in
                guard let b = blank else { next(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let url = b.preview?.webView.url?.absoluteString ?? "nil"
                    expect(url == "about:blank" && b.preview?.lastLinkAction == nil && b.preview?.isHome == true && b.preview?.webView.isLoading == false,
                           "and WebKit never navigated: the page is still about:blank, nothing routed",
                           "\(url) action \(String(describing: b.preview?.lastLinkAction))")
                    previewJS(b, "document.body.innerText.includes('the far section') + ''") { v in
                        expect(v as? String == "true", "and still shows the document", "\(v ?? "nil")")
                        next()
                    }
                }
            },
        ] } + [
            sync { for t in app.tabs { t.doc.markSaved() } },
        ])
    }

    /// A 1 MB Markdown file with the preview open: the main thread's time
    /// per keystroke and per preview update.
    static func perfBigMarkdown(_ app: AppDelegate, _ small: EditorWindowController, _ next: @escaping () -> Void) {
        var unit = "## Part\n\nSome **bold** and *em* text with `code` and a [link](https://example.com). Another sentence to fill.\n\n"
        unit += "- one\n- two\n  - nested\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet x = 1\n```\n\n> quoted line\n\n"
        let big = String(repeating: unit, count: 1_048_576 / unit.utf8.count + 1)
        let tab = app.open(write("big.md", big))!
        sized(tab)
        focus(tab)
        let t0 = DispatchTime.now()
        _ = Markdown.render(big, options: .preview)
        let renderMs = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        print("check: metric md_1mb_render_ms=\(String(format: "%.1f", renderMs)) (now off the main thread)")
        tab.togglePreview()
        var keyMs: [Double] = []
        var updateMs: [Double] = []
        var rounds = 0
        @MainActor func round() {
            guard rounds < 12, let p = tab.preview else { finish(); return }
            rounds += 1
            let before = p.bodySwaps + p.pageLoads
            p.resetMainThreadTimes()
            tab.textView.setSelectedRange(NSRange(location: 40 + rounds * 7, length: 0))
            let k0 = DispatchTime.now()
            type("x")
            keyMs.append(Double(DispatchTime.now().uptimeNanoseconds - k0.uptimeNanoseconds) / 1e6)
            let deadline = Date().addingTimeInterval(8)
            @MainActor func wait() {
                if p.bodySwaps + p.pageLoads > before {
                    updateMs.append(p.mainThreadTimes.max() ?? 0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { round() } }
                } else if Date() > deadline {
                    expect(false, "1 MB: the preview updates", "no render")
                    finish()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { MainActor.assumeIsolated { wait() } }
                }
            }
            wait()
        }
        @MainActor func finish() {
            func median(_ a: [Double]) -> Double { a.isEmpty ? -1 : a.sorted()[a.count / 2] }
            let kMed = median(keyMs), uMax = updateMs.max() ?? -1
            print("check: metric md_1mb_key_median_ms=\(String(format: "%.2f", kMed)) key_max_ms=\(String(format: "%.2f", keyMs.max() ?? -1))")
            print("check: metric md_1mb_preview_main_thread_max_ms=\(String(format: "%.2f", uMax)) median=\(String(format: "%.2f", median(updateMs))) background_render_ms=\(String(format: "%.1f", tab.preview?.lastRenderMs ?? -1))")
            expect(updateMs.count >= 10, "1 MB: the preview updates after each pause", "\(updateMs.count)")
            expect(kMed < 16, "1 MB: a keystroke stays under a frame with the preview open", "\(kMed) ms")
            // The median is the cost; the worst one is checked loosely (a busy machine deschedules us now and then).
            expect(median(updateMs) < 8, "1 MB: a preview update costs the main thread a few ms at most (median)", "\(median(updateMs)) ms")
            expect(uMax < 50, "1 MB: and never more than a few frames", "\(uMax) ms")
            tab.doc.markSaved()
            next()
        }
        // Let the first full render land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { MainActor.assumeIsolated { round() } }
    }

    // MARK: Outline

    static func waitForOutline(_ tab: EditorWindowController, after: @escaping () -> Int, _ name: String) -> (@escaping () -> Void) -> Void {
        { next in
            let start = after()
            let deadline = Date().addingTimeInterval(5)
            @MainActor func poll() {
                if (tab.outline.sidebar?.builds ?? 0) > start { next() }
                else if Date() > deadline { expect(false, name, "no rebuild"); next() }
                else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } } }
            }
            poll()
        }
    }

    static func outlineCheck(_ app: AppDelegate) {
        var text = "# Guide\n\nIntro.\n\n```sh\n# not a heading\n```\n\n"
        for k in 1...30 { text += "## Section \(k)\n\nBody \(k).\n\n" }
        text += "Setext Title\n---\n\nend\n"
        let tab = app.open(write("guide.md", text))!
        let code = app.open(write("code.swift", "// # nope\n"))!
        sized(tab); sized(code)
        var side: OutlineSidebar? { tab.outline.sidebar }
        let ns = { tab.text as NSString }
        func caretLine() -> Int { tab.lineIndex.line(containing: tab.textView.selectedRange().location) }
        var builds = 0
        run([
            sync {
                focus(code)
                if let i = menuItem(action: #selector(AppDelegate.toggleOutlineMenu(_:))) {
                    expect(!app.validateMenuItem(i), "View › Show Outline is off for a Swift file")
                }
                focus(tab)
                if let i = menuItem(action: #selector(AppDelegate.toggleOutlineMenu(_:))) {
                    expect(app.validateMenuItem(i) && i.state == .off && i.title == "Show Outline", "and on for Markdown", i.title)
                }
                expect(tab.outline.sidebar == nil, "the outline isn't built until it is first shown")
                key("o", [.control, .command])
                expect(tab.outlineVisible, "⌃⌘O shows the outline")
            },
            waitForOutline(tab, after: { 0 }, "the outline is built"),
            sync {
                let titles = side?.headings.map(\.title) ?? []
                expect(titles.count == 32 && titles.first == "Guide" && titles.last == "Setext Title", "it lists the # and setext headings",
                       "\(titles.count) \(titles.prefix(3)) \(titles.suffix(1))")
                expect(!titles.contains("not a heading"), "but not a # inside fenced code")
                expect((side?.frame.width ?? 0) > 100 && (tab.scrollView.frame.minX) >= (side?.frame.maxX ?? 0), "it sits left of the text",
                       "\(side?.frame ?? .zero) \(tab.scrollView.frame)")
                let target = ns().range(of: "Body 10.")
                tab.textView.setSelectedRange(NSRange(location: target.location, length: 0))
                let sel = side?.selectedHeading?.title ?? "-"
                expect(sel == "Section 10", "the heading the caret is under is selected", sel)
            },
            snapshot("outline.png"),
            sync {
                // A click on a row jumps there. (A real click when Cedric is the
                // active app; when it isn't, NSTableView ignores the synthetic
                // mouse-down, so the row is selected as the click would.)
                guard let s = side, let row = s.rows.firstIndex(where: { s.headings[$0].title == "Section 25" }) else { return }
                s.table.scrollRowToVisible(row)
                let r = s.table.rect(ofRow: row)
                clickDirect(s.table, at: NSPoint(x: r.midX, y: r.midY))
                if s.table.selectedRow != row { s.table.selectRowIndexes([row], byExtendingSelection: false) }
                let want = s.headings[s.rows[row]].line
                expect(caretLine() == want, "clicking a heading puts the caret on it", "\(caretLine()) want \(want)")
                expect(tab.topLine <= want && tab.topLine >= want - 30, "and scrolls it into view", "top \(tab.topLine)")
                builds = s.builds
                // Typing a new heading: the outline follows when typing pauses.
                tab.textView.setSelectedRange(NSRange(location: ns().length, length: 0))
                type("\r# Appendix")
            },
            waitForOutline(tab, after: { builds }, "typing rebuilds the outline"),
            sync {
                expect(side?.headings.last?.title == "Appendix", "with the new heading", side?.headings.last?.title ?? "-")
                key("o", [.control, .command])
                expect(!tab.outlineVisible, "⌃⌘O hides it again")
                // Go to Heading: the outline with its filter focused.
                key("j", [.command, .shift])
                expect(tab.outlineVisible && tab.outline.transient, "⇧⌘J opens it for the jump")
                expect(tab.window?.firstResponder === side?.field.currentEditor(), "with the filter focused")
                type("tion 7")
                expect(side?.rows.count == 1 && side?.selectedHeading?.title == "Section 7", "typing filters the headings",
                       "\(side?.rows.count ?? -1) \(side?.selectedHeading?.title ?? "-")")
                key("\r")
                let want = side?.headings.first { $0.title == "Section 7" }?.line ?? -1
                expect(caretLine() == want, "Return jumps to it", "\(caretLine()) want \(want)")
                expect(!tab.outlineVisible && tab.window?.firstResponder === tab.textView, "and puts the outline away again, focus back in the text")
                // Esc: back to the text, nowhere else.
                key("j", [.command, .shift])
                type("Sect")
                let before = caretLine()
                key("\u{1b}")
                expect(!tab.outlineVisible && caretLine() == before && tab.window?.firstResponder === tab.textView, "Esc goes back to the text")
                for t in [tab, code] { t.doc.markSaved() }
            },
        ])
    }

    // MARK: Export and copy

    static func exportCheck(_ app: AppDelegate) {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
        try? png.write(to: dir.appendingPathComponent("dot.png"))
        var body = "---\ntitle: Report\n---\n# Quarterly report\n\nSome **bold** text[^1] and ![dot](dot.png).\n\n```swift\nlet answer = 42\n```\n\n"
        for k in 1...80 { body += "Paragraph \(k) of filler text so the PDF runs over more than one page.\n\n" }
        body += "[^1]: A note.\n"
        let tab = app.open(write("report.md", body))!
        let swift = app.open(write("x.swift", "let a = 1\n"))!
        sized(tab); sized(swift)
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        let pdfURL = dir.appendingPathComponent("out/report.pdf")
        try? FileManager.default.createDirectory(at: pdfURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        run([
            sync {
                focus(swift)
                for a in [#selector(AppDelegate.exportHTMLMenu(_:)), #selector(AppDelegate.exportPDFMenu(_:)),
                          #selector(AppDelegate.copyAsHTMLMenu(_:)), #selector(AppDelegate.copyAsRichTextMenu(_:))] {
                    if let i = menuItem(action: a) { expect(!app.validateMenuItem(i), "\(i.title) is off for a Swift file") } else { expect(false, "menu item \(a)") }
                }
                focus(tab)
                if let i = menuItem(action: #selector(AppDelegate.exportPDFMenu(_:))) { expect(app.validateMenuItem(i), "and on for Markdown") }
                // Copy as HTML: the selection, rendered.
                let ns = tab.text as NSString
                tab.textView.setSelectedRange(ns.range(of: "Some **bold** text"))
            },
            { next in
                // Copy as HTML renders off the main thread, then fills the pasteboard.
                pb.clearContents()
                tab.copyAsHTML {
                    expect(pb.string(forType: .string) == "<p data-line=\"0\">Some <strong>bold</strong> text</p>\n", "Copy as HTML copies the selection's HTML",
                           pb.string(forType: .string) ?? "-")
                    next()
                }
            },
            { next in
                let ns = tab.text as NSString
                tab.textView.setSelectedRange(NSRange(location: ns.range(of: "```swift").location, length: 30))
                tab.copyAsRichText { next() }
            },
            sync {
                let rtf = pb.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) }
                expect(rtf?.string.contains("let answer = 42") == true, "Copy as Rich Text puts RTF on the pasteboard", rtf?.string ?? "-")
                let colours = Set((0..<(rtf?.length ?? 0)).compactMap { rtf?.attribute(.foregroundColor, at: $0, effectiveRange: nil) as? NSColor })
                expect(colours.count >= 2, "with the code's colours", "\(colours.count) colours")
                expect(pb.string(forType: .html)?.contains("tk-keyword") == true && pb.string(forType: .string)?.contains("let answer") == true,
                       "and HTML and plain text too")
                // Export as HTML: a standalone light page; script forbidden by CSP, none in it.
                let page = EditorWindowController.exportPage(markdown: tab.text, title: tab.exportBaseName)
                expect(page.contains("<title>report</title>") && page.contains("color-scheme: light") && page.contains("script-src 'none'")
                       && !page.contains("<script"), "Export as HTML writes a standalone, light page")
                // Security audit L4: raw HTML blocks' script and handlers don't survive export.
                let hostile = EditorWindowController.exportPage(markdown: "<script>alert(1)</script>\n\n<img src=\"a.png\" onerror=\"alert(2)\">\n", title: "x")
                expect(!hostile.contains("<script") && !hostile.contains("onerror") && hostile.contains("a.png"),
                       "an exported page has no <script> or on…= handlers from the Markdown")
                expect(page.contains("class=\"frontmatter\"") && page.contains("tk-keyword") && page.contains("id=\"fn-1\""),
                       "rendered as the preview renders it")
            },
            { next in
                MarkdownPDFExport.run(markdown: tab.text, folder: tab.doc.fileURL?.deletingLastPathComponent(), title: "report", to: pdfURL) { error in
                    let pdf = PDFDocument(url: pdfURL)
                    expect(error == nil && (pdf?.pageCount ?? 0) >= 2, "Export as PDF writes a paginated PDF", "\(error.map { "\($0)" } ?? "") pages \(pdf?.pageCount ?? 0)")
                    let text = pdf?.string ?? ""
                    expect(text.contains("Quarterly report") && text.contains("Paragraph 80") && !text.contains("**"),
                           "of the rendered document", String(text.prefix(80)))
                    if let page = pdf?.page(at: 0) { print("check: note: PDF page size \(page.bounds(for: .mediaBox).size)") }
                    try? FileManager.default.removeItem(at: out.appendingPathComponent("export.pdf"))
                    try? FileManager.default.copyItem(at: pdfURL, to: out.appendingPathComponent("export.pdf"))
                    next()
                }
            },
            // Obsidian syntax leaves the app: wikilinks and embeds by relative
            // path (no cedric-doc: links), notes inlined, unresolved as text.
            { next in
                let wiki = dir.appendingPathComponent("wiki", isDirectory: true)
                try? FileManager.default.createDirectory(at: wiki.appendingPathComponent("att"), withIntermediateDirectories: true)
                try? png.write(to: wiki.appendingPathComponent("att/dot.png"))
                _ = write("wiki/Other Note.md", "# Other\n\n## Part\n\nTranscluded words.\n")
                let md = "# Wiki export\n\nSee [[Other Note|the other]] and [[Gone]].\n\n![[dot.png|40]]\n\n![[Other Note#Part]]\n"
                let vault = WikiVault(documentFolder: wiki)
                let html = EditorWindowController.exportPage(markdown: md, title: "wiki", vault: vault)
                expect(!html.contains("cedric-doc") && html.contains("href=\"Other%20Note.md\">the other</a>") && html.contains("src=\"att/dot.png\"")
                       && html.contains("Transcluded words.") && html.contains(" and Gone."),
                       "exported HTML: wikilinks and embeds by relative path, the note inlined, unresolved as text")
                let u = dir.appendingPathComponent("out/wiki.pdf")
                MarkdownPDFExport.run(markdown: md, folder: wiki, title: "wiki", to: u) { error in
                    let pdf = PDFDocument(url: u)
                    let text = pdf?.string ?? ""
                    var urls: [String] = []
                    for k in 0..<(pdf?.pageCount ?? 0) {
                        for a in pdf?.page(at: k)?.annotations ?? [] { if let s = a.url?.absoluteString { urls.append(s) } }
                    }
                    print("check: note: wiki PDF link annotations \(urls)")
                    expect(error == nil && text.contains("Transcluded words.") && text.contains("the other") && !text.contains("[["),
                           "exported PDF: the note inlined, wikilinks as text", String(text.prefix(120)))
                    expect(!urls.isEmpty && urls.allSatisfy { $0 == "../wiki/Other%20Note.md" }, "exported PDF: links relative to the PDF, no cedric-doc:", "\(urls)")
                    try? FileManager.default.removeItem(at: out.appendingPathComponent("export-wiki.pdf"))
                    try? FileManager.default.copyItem(at: u, to: out.appendingPathComponent("export-wiki.pdf"))
                    next()
                }
            },
            // 20 exports in a row: each one tears its offscreen page down cleanly.
            { next in
                var k = 0, ok = 0
                @MainActor func one() {
                    guard k < 20 else {
                        expect(ok == 20, "20 PDF exports in a row all succeed", "\(ok) of 20")
                        DispatchQueue.main.async { DispatchQueue.main.async {
                            expect(MarkdownPDFExport.runningCount == 0, "and none is left running", "\(MarkdownPDFExport.runningCount)")
                            next()
                        } }
                        return
                    }
                    k += 1
                    let u = dir.appendingPathComponent("out/loop-\(k).pdf")
                    MarkdownPDFExport.run(markdown: "# Run \(k)\n\ntext\n", folder: dir, title: "loop", to: u) { error in
                        if error == nil, PDFDocument(url: u)?.string?.contains("Run \(k)") == true { ok += 1 }
                        one()
                    }
                }
                one()
            },
            // An export from a tab that closes while the PDF is being made.
            { next in
                let closing = app.open(write("closing.md", "# Closing\n\nbye\n"))!
                let u = dir.appendingPathComponent("out/closing.pdf")
                MarkdownPDFExport.run(markdown: closing.text, folder: dir, title: "closing", to: u) { error in
                    expect(error == nil && PDFDocument(url: u)?.string?.contains("Closing") == true,
                           "an export finishes after its tab closed", "\(error.map { "\($0)" } ?? "")")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() }
                }
                closing.doc.markSaved()
                closing.window?.performClose(nil)
            },
            sync {
                pb.clearContents()
                if let saved { pb.setString(saved, forType: .string) }
                for t in [tab, swift] { t.doc.markSaved() }
            },
        ])
    }
}
