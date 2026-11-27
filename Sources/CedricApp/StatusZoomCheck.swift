import AppKit
import CedricCore

/// CEDRIC_CHECK=statuszoom (Scripts/tools-check.sh, 0.2.1): the status
/// bar's zoom is a pull-down (Zoom In, Zoom Out, Actual Size, 75–200 %)
/// that zooms the editor, and with the preview docked the editor's status
/// items stay under the editor column, a split editor's two panes too
/// (0.3.0). CSV / TSV: the Preview eye just before the language pull-down
/// ("CSV / TSV"), hidden for every other language; off at first; a click,
/// VoiceOver's press, ⌥⌘P, Detach, Attach and closing the detached window
/// all keep it in step; label, value and tooltip; both themes.
@MainActor
extension DevChecks {
    static func statusZoomCheck(_ app: AppDelegate) {
        let tab = app.open(write("zoom.md", "# Zoom\n\nText.\n"))!
        sized(tab)
        let bar = tab.statusBar
        let start = Settings.shared.fontSize
        func item(_ title: String) -> NSMenuItem? { bar.zoom.itemArray.dropFirst().first { $0.title == title } }
        /// Runs a pop-up item as a click does: its action up the responder chain.
        func choose(_ title: String) {
            guard let i = item(title), let a = i.action else { expect(false, "zoom item \(title)", "missing"); return }
            NSApp.sendAction(a, to: i.target, from: i)
        }
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(tab)
                Settings.shared.fontSize = Settings.defaultFontSize
                let titles = bar.zoom.itemArray.dropFirst().map(\.title)
                expect(titles == ["Zoom In", "Zoom Out", "Actual Size", "", "75%", "90%", "100%", "110%", "125%", "150%", "200%"],
                       "the zoom is a pull-down with Zoom In / Out, Actual Size and 75–200 %", "\(titles)")
                expect(!bar.zoom.isHidden && bar.zoom.titleOfSelectedItem == "100%" && bar.zoom.stringValue == "100%", "titled 100%",
                       bar.zoom.titleOfSelectedItem ?? "-")
                let keys = ["Zoom In", "Zoom Out", "Actual Size"].map { item($0).map { "\($0.keyEquivalent)\($0.keyEquivalentModifierMask == .command)" } ?? "-" }
                expect(keys == ["=true", "-true", "0true"], "showing ⌘+ ⌘− ⌘0", "\(keys)")
                expect(item("100%")?.state == .on && item("110%")?.state == .off, "a tick on the current size")
                choose("125%")
                expect(Settings.shared.fontSize == Settings.defaultFontSize * 1.25 && bar.zoom.stringValue == "125%",
                       "125% zooms the editor", "\(Settings.shared.fontSize) \(bar.zoom.stringValue)")
                choose("Zoom In")
                expect(Settings.shared.fontSize == Settings.defaultFontSize * 1.25 + 1, "Zoom In", "\(Settings.shared.fontSize)")
                choose("Zoom Out"); choose("Zoom Out")
                expect(Settings.shared.fontSize == Settings.defaultFontSize * 1.25 - 1, "Zoom Out", "\(Settings.shared.fontSize)")
                choose("Actual Size")
                expect(Settings.shared.fontSize == Settings.defaultFontSize && bar.zoom.stringValue == "100%", "Actual Size")
                // ⌘= is the View menu's, once: the pop-up only shows the shortcut.
                let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: tab.window?.windowNumber ?? 0,
                                         context: nil, characters: "=", charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24)
                expect(e.map { !bar.zoom.performKeyEquivalent(with: $0) } == true, "the pop-up leaves ⌘= to the View menu")
                tab.window?.layoutIfNeeded()
                expect(abs(bar.itemsFrame.maxX - bar.bounds.maxX) < 1, "no preview: the items reach the right edge",
                       "\(bar.itemsFrame) in \(bar.bounds)")
                tab.togglePreview()
            },
            snapshot("statuszoom-docked.png"),
            sync {
                tab.window?.layoutIfNeeded()
                let column = tab.editorArea.frame
                let items = bar.itemsFrame
                expect(tab.previewVisible && column.maxX < bar.bounds.width - 100, "the preview is docked beside the editor", "\(column)")
                expect(abs(items.maxX - column.maxX) < 1 && items.minX >= column.minX - 1,
                       "the status items sit under the editor column, not under the preview", "items \(items) column \(column)")
                let zoom = bar.zoom.convert(bar.zoom.bounds, to: bar)
                expect(zoom.maxX <= column.maxX, "the zoom too", "\(zoom)")
                // 0.3.0: a split editor is one column for the status bar.
                tab.splitPanes(sideBySide: true, ratio: 0.5, focusSecond: true)
            },
            snapshot("statuszoom-split.png"),
            sync {
                tab.window?.layoutIfNeeded()
                let column = tab.editorArea.frame
                let items = bar.itemsFrame
                expect(tab.isSplit && tab.previewVisible && tab.editorArea !== tab.editorContainer, "split side by side, preview docked")
                expect(abs(items.maxX - column.maxX) < 1 && items.minX >= column.minX - 1 && column.maxX > tab.primaryPane.container.frame.maxX + 100,
                       "split: the status items span both panes, not the first pane or the preview", "items \(items) column \(column)")
                tab.unsplit()
            },
            sync {
                tab.window?.layoutIfNeeded()
                let column = tab.editorArea.frame
                expect(!tab.isSplit && abs(bar.itemsFrame.maxX - column.maxX) < 1, "unsplit: still under the editor column",
                       "items \(bar.itemsFrame) column \(column)")
                tab.togglePreview()
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                tab.window?.layoutIfNeeded()
                expect(abs(bar.itemsFrame.maxX - bar.bounds.maxX) < 1, "preview closed: back to the full width", "\(bar.itemsFrame)")
                Settings.shared.fontSize = start
                expect(bar.previewButton.isHidden, "Markdown: no status-bar eye (its Context Bar has one)")
                // Hidden for every other language; shown for CSV / TSV only.
                let other = app.open(write("other.txt", "plain\n"))!
                sized(other)
                for l in [Language.plain, .html, .swift, .json, .markdown] {
                    other.setLanguage(l)
                    expect(other.statusBar.previewButton.isHidden, "\(l.rawValue): no status-bar eye")
                }
                other.setLanguage(.csv)
                expect(!other.statusBar.previewButton.isHidden, "a tab switched to CSV / TSV shows the eye")
                other.setLanguage(.swift)
                expect(other.statusBar.previewButton.isHidden, "and back in Swift it goes")
                other.doc.markSaved()
                other.window?.performClose(nil)
                TypingCheck.apply(TypingCheck.ThemeCase(name: "dark", theme: .dark, system: nil))
                let csv = app.open(write("status.csv", "name,city\nAnn,Oslo\nBo,Rome\n"))!
                sized(csv)
                focus(csv)
                csv.window?.layoutIfNeeded()
                expectCSVEye(csv, on: false, "CSV, dark")
                let sb = csv.statusBar, eye = sb.previewButton, lang = sb.languageButton
                expect(csv.doc.language == .csv && lang.title == csv.doc.languageChoice.displayTitle, "a .csv file: the picker shows its format", lang.title)
                let ef = eye.convert(eye.bounds, to: sb), lf = lang.convert(lang.bounds, to: sb)
                expect(ef.maxX <= lf.minX && lf.minX - ef.maxX < 10, "the eye sits right before the format picker", "eye \(ef) picker \(lf)")
                let between = [sb.gitButton, sb.zoom, sb.encodingButton, sb.lineEndingButton].filter { !$0.isHidden }
                    .map { $0.convert($0.bounds, to: sb) }.filter { $0.midX > ef.maxX && $0.midX < lf.minX }
                expect(between.isEmpty, "nothing between the eye and the picker", "\(between)")
                expect(abs(ef.midY - lf.midY) < 2 && ef.height <= 24 && sb.frame.height == 24, "on the 24 pt status row, centred with the picker",
                       "eye \(ef) picker \(lf) bar \(sb.frame.height)")
                expect(!eye.isBordered && eye.controlSize == .small, "a status-bar control: unbordered, small")
                expect(eye.toolTip == "Preview (⌥⌘P)", "tooltip with the menu's shortcut", eye.toolTip ?? "-")
                expect(sb.window?.appearance?.name == .darkAqua || csv.palette.isDark, "dark theme")
            },
            snapshot("statusbar-csv-dark-off.png"),
            sync {
                guard let csv = namedTab(app, "status.csv") else { return }
                let eye = csv.statusBar.previewButton
                click(eye, at: NSPoint(x: eye.bounds.midX, y: eye.bounds.midY))
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() } },
            sync {
                guard let csv = namedTab(app, "status.csv") else { return }
                expect(csv.previewVisible && !csv.previewDetached && csv.previewPane?.renderer is CSVPreview, "CSV: a click on the eye docks the grid")
                expectCSVEye(csv, on: true, "CSV, dark, after a click")
                csv.window?.layoutIfNeeded()
                let sb = csv.statusBar, column = csv.editorArea.frame
                let ef = sb.previewButton.convert(sb.previewButton.bounds, to: sb)
                expect(abs(sb.itemsFrame.maxX - column.maxX) < 1 && ef.maxX <= column.maxX,
                       "CSV docked: the eye and the status items stay under the editor column", "items \(sb.itemsFrame) eye \(ef) column \(column)")
            },
            snapshot("statusbar-csv-dark-on.png"),
            sync {
                TypingCheck.apply(TypingCheck.ThemeCase(name: "light", theme: .light, system: nil))
                guard let csv = namedTab(app, "status.csv") else { return }
                csv.window?.layoutIfNeeded()
                expect(!csv.palette.isDark, "light theme")
                expectCSVEye(csv, on: true, "CSV, light")
            },
        ]
        steps += steps2
        let steps3: [Step] = [
            snapshot("statusbar-csv-light-on.png"),
            sync {
                guard let csv = namedTab(app, "status.csv") else { return }
                let eye = csv.statusBar.previewButton
                click(eye, at: NSPoint(x: eye.bounds.midX, y: eye.bounds.midY))
                expect(!csv.previewVisible, "CSV: a second click hides the grid")
                expectCSVEye(csv, on: false, "CSV, light, second click")
                csv.window?.layoutIfNeeded()
            },
            snapshot("statusbar-csv-light-off.png"),
            sync {
                TypingCheck.apply(TypingCheck.ThemeCase(name: "dark", theme: .dark, system: nil))
                // TSV: VoiceOver's press, ⌥⌘P, Detach, Attach, closing the detached window.
                let tsv = app.open(write("status.tsv", "a\tb\n1,5\t2\n"))!
                sized(tsv)
                focus(tsv)
                tsv.window?.layoutIfNeeded()
                expect(tsv.doc.language == .csv, "a .tsv file is CSV / TSV", tsv.doc.language.rawValue)
                expectCSVEye(tsv, on: false, "TSV")
                _ = tsv.statusBar.previewButton.accessibilityPerformPress()
                expect(tsv.previewVisible, "TSV: VoiceOver's press shows the grid")
                expectCSVEye(tsv, on: true, "TSV, VoiceOver press")
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() } },
            sync {
                guard let tsv = namedTab(app, "status.tsv") else { return }
                let grid = tsv.previewPane?.renderer as? CSVPreview
                expect(grid?.data.delimiter == 9, "TSV: the grid is tab-separated", "\(String(describing: grid?.data.delimiter))")
                focus(tsv)
                key("p", [.command, .option])
                expect(!tsv.previewVisible, "TSV: ⌥⌘P hides it")
                expectCSVEye(tsv, on: false, "TSV, ⌥⌘P")
                key("p", [.command, .option])
                expectCSVEye(tsv, on: true, "TSV, ⌥⌘P again")
                key("p", [.command, .option, .shift])
                expect(tsv.previewDetached, "TSV: ⇧⌥⌘P detaches it")
                expectCSVEye(tsv, on: true, "TSV, detached")
                tsv.attachPreview()
                expect(tsv.previewVisible && !tsv.previewDetached, "TSV: Attach docks it again")
                expectCSVEye(tsv, on: true, "TSV, attached")
                tsv.detachPreview()
                tsv.previewWindow?.window?.performClose(nil)
                expect(!tsv.previewVisible, "TSV: closing the detached window closes the preview")
                expectCSVEye(tsv, on: false, "TSV, detached window closed")
                for t in app.tabs where ["status.csv", "status.tsv"].contains(t.doc.fileURL?.lastPathComponent ?? "") {
                    t.doc.markSaved()
                    t.window?.performClose(nil)
                }
            },
        ]
        steps += steps3
        run(steps)
    }

    private static func namedTab(_ app: AppDelegate, _ name: String) -> EditorWindowController? {
        let t = app.tabs.first { $0.doc.fileURL?.lastPathComponent == name }
        if t == nil { expect(false, "the \(name) tab") }
        return t
    }

    /// The CSV / TSV status-bar eye: shown, on or off with the preview,
    /// labelled Preview for VoiceOver with on/off as its value, tinted
    /// secondary (off) or label (on).
    private static func expectCSVEye(_ t: EditorWindowController, on: Bool, _ what: String) {
        let eye = t.statusBar.previewButton
        let value = eye.accessibilityValue() as? String
        expect(!eye.isHidden && eye.isEnabled, "\(what): the status-bar eye is shown")
        expect(t.previewVisible == on && (eye.state == .on) == on, "\(what): the eye is \(on ? "on" : "off")",
               "state \(eye.state.rawValue) preview \(t.previewVisible)")
        expect(eye.accessibilityLabel() == "Preview" && value == (on ? "on" : "off"), "\(what): VoiceOver hears Preview, \(on ? "on" : "off")",
               "\(eye.accessibilityLabel() ?? "-") \(value ?? "-")")
        expect(eye.contentTintColor == (on ? NSColor.labelColor : .secondaryLabelColor), "\(what): the eye's tint", "\(String(describing: eye.contentTintColor))")
    }
}
