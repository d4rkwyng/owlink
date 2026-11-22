#if DEBUG
import UIKit
import SwiftUI
import CedricCore
import CedricAI

/// Debug builds only: `-OwlinkSelfCheck <dir>` runs the editor through a
/// script inside the app (open a sample, type, save, read the file back;
/// the owl's hint and Fix it; the Markdown preview; themes), renders each
/// step's window to <dir>/<name>.png, writes <dir>/selfcheck.txt with
/// PASS/FAIL lines, and quits. Made for a Mac whose iOS simulator can't
/// draw: run as a Mac Catalyst build (README-ios.md). On a device or a
/// working simulator, OwlinkUITests and OwlinkSnapshotTests do the same.
@MainActor
enum SelfCheck {
    static var outDir: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-OwlinkSelfCheck"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    private static var log: [String] = []
    private static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        log.append((ok ? "PASS " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    static func run(in window: UIWindow, browser: UIViewController, out: URL) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            // iPhone Duo inner display: 669 x 951 pt, read from a real
            // Duo screenshot (2007 x 2853 px at 3x); the cover display's
            // point size isn't confirmed, so it isn't listed.
            let shapes: [(String, CGSize, UIUserInterfaceSizeClass)] = [
                ("iphone", CGSize(width: 402, height: 874), .compact),
                ("ipad", CGSize(width: 1194, height: 834), .regular),
                ("duo-open", CGSize(width: 669, height: 951), .regular),
                ("duo-open-landscape", CGSize(width: 951, height: 669), .regular),
            ]
            for (device, size, sizeClass) in shapes {
                resize(window, to: size)
                for dark in [false, true] {
                    window.overrideUserInterfaceStyle = dark ? .dark : .light
                    let mode = dark ? "dark" : "light"
                    await shot(window, browser, sample: "sample.swift", sizeClass: sizeClass, name: "\(device)-\(mode)-swift") { editor in
                        if device == "iphone" && !dark { await behaviour(editor) }
                    }
                    await shot(window, browser, sample: "README.md", sizeClass: sizeClass, name: "\(device)-\(mode)-markdown-preview") { editor in
                        if device == "iphone" && !dark { markdownBar(editor) }
                        editor.togglePreview()
                        check(editor.previewOn, "\(device) \(mode): preview on")
                        try? await Task.sleep(for: .seconds(2))
                    }
                }
            }
            resize(window, to: shapes[0].1)
            window.overrideUserInterfaceStyle = .light
            await shot(window, browser, sample: "sample.swift", sizeClass: .compact, name: "iphone-light-ask-cedric") { editor in
                await askCedric(editor, window: window)
            }
            window.overrideUserInterfaceStyle = .dark
            AppSettings.theme = .dracula
            await shot(window, browser, sample: "sample.swift", sizeClass: .compact, name: "iphone-dracula-swift") { _ in }
            AppSettings.theme = .system
            let settings = UIHostingSettings.make()
            settings.modalPresentationStyle = .fullScreen
            browser.present(settings, animated: false)
            try? await Task.sleep(for: .seconds(1))
            render(window, out.appendingPathComponent("iphone-settings.png"))
            check(BuiltInEngine().unavailableReason != nil || BuiltInPlatform.runtime != nil, "built-in engine state reported")
            log.append("INFO Apple Intelligence: \(AIStatus.appleLine)")
            log.append("INFO Built-in: \(BuiltInEngine().unavailableReason ?? "available")")
            browser.dismiss(animated: false)
            log.append(failures == 0 ? "selfcheck: all passed" : "selfcheck: \(failures) failed")
            try? log.joined(separator: "\n").appending("\n").write(to: out.appendingPathComponent("selfcheck.txt"), atomically: true, encoding: .utf8)
            exit(failures == 0 ? 0 : 1)
        }
    }

    static func resize(_ window: UIWindow, to size: CGSize) {
        guard let scene = window.windowScene else { return }
        scene.sizeRestrictions?.minimumSize = size
        scene.sizeRestrictions?.maximumSize = size
        scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(origin: CGPoint(x: 40, y: 40), size: size)))
    }

    /// The behaviour checks, on a fresh sample.swift.
    static func behaviour(_ editor: EditorViewController) async {
        let doc = editor.document
        check(doc.language.language == .swift, "language detected: Swift")
        check(editor.textView.inputAccessoryView == nil, "code has no context bar")
        check(doc.encoding == .utf8 && doc.lineEnding == .lf, "encoding UTF-8, line ending LF")
        for _ in 0..<30 where editor.owl.visible == nil { try? await Task.sleep(for: .milliseconds(200)) }
        let hint = editor.owl.visible?.hint.title ?? "none"
        check(hint.contains("spaces"), "owl hint shown: \(hint)")
        check(!editor.owlSprite.isHidden && editor.owlSprite.badge.isHidden == false, "owl shows a hint badge")
        check(editor.owlSprite.bounds.width >= 44, "owl is at least 44 pt")
        editor.openHint()
        check(!editor.hintBar.isHidden, "hint bubble opens on tap")
        editor.applyFix()
        check(!editor.textView.text.contains("struct Owl {   "), "Fix it trimmed the trailing spaces")
        check(editor.textView.undoManager?.canUndo == true, "the fix is undoable")
        editor.textView.selectedRange = NSRange(location: (editor.textView.text as NSString).length, length: 0)
        editor.textView.insertText("// typed by the self-check\n")
        let saved = await withCheckedContinuation { c in doc.save(to: doc.fileURL, for: .forOverwriting) { c.resume(returning: $0) } }
        check(saved, "saved")
        let back = (try? String(contentsOf: doc.fileURL, encoding: .utf8)) ?? ""
        check(back.hasSuffix("// typed by the self-check\n") && !back.contains("struct Owl {   "), "file on disk has the edit and the fix")
        let pattern = "^[a-z]+$"
        editor.textView.insertText(pattern)
        let full = editor.textView.text as NSString
        let regexRange = full.range(of: pattern, options: .backwards)
        check(editor.textToolStates(selection: regexRange).explain, "Explain Regex available for a regex selection")
        let stats = StatisticsViewController(text: "one two\nthree", selection: NSRange(location: 0, length: 7), filePath: doc.fileURL.path)
        stats.loadViewIfNeeded()
        func labels(_ view: UIView) -> [String] {
            [view.accessibilityLabel].compactMap { $0 } + view.subviews.flatMap { labels($0) }
        }
        for _ in 0..<30 {
            if labels(stats.view).contains(where: { $0.contains("Document") && $0.contains("Words") && $0.contains("3") }) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let figures = labels(stats.view)
        check(figures.contains { $0.contains("Document") && $0.contains("Words") && $0.contains("3") }
              && figures.contains { $0.contains("Selection") && $0.contains("Words") && $0.contains("2") },
              "statistics count document and selection words")
        editor.textView.undoManager?.undo()
        editor.setLanguage(.python)
        check(doc.language.isManual && doc.language.language == .python, "language menu: manual choice")
        editor.setLanguage(.swift)
        let find = editor.textView.findInteraction
        check(find != nil, "find interaction present")
        // Wait for the hint the edit may bring back to settle before the shot.
        try? await Task.sleep(for: .seconds(1))
    }

    static func markdownBar(_ editor: EditorViewController) {
        AppSettings.showContextBar = true
        let bar = editor.contextBar
        let ids = ContextBarSet.items(for: .markdown).map(\.id)
        check(bar != nil && bar?.items.map(\.id) == ids && Set(bar?.buttons.keys.map { $0 } ?? []) == Set(ids),
              "Markdown context bar has the shared items")
        let original = editor.textView.text ?? ""
        guard !original.isEmpty else { check(false, "Markdown sample has text"); return }
        editor.textView.becomeFirstResponder()
        editor.textView.selectedRange = NSRange(location: 0, length: 1)
        editor.markdownBoldMenu(nil)
        check(editor.textView.text != original, "Markdown Bold changes the selection")
        editor.textView.undoManager?.undo()
        check(editor.textView.text == original, "one Undo restores Markdown Bold")
        editor.textView.text = "- item"
        editor.textView.selectedRange = NSRange(location: 6, length: 0)
        let continued = !editor.textView(editor.textView, shouldChangeTextIn: editor.textView.selectedRange, replacementText: "\n")
            && editor.textView.text == "- item\n- "
        check(continued, "Markdown list continues on Return")
        editor.textView.text = original
        editor.textView.selectedRange = NSRange(location: 0, length: 0)
    }

    /// Ask Cedric for real when an engine is ready here (Apple
    /// Intelligence on this Mac or device); otherwise checks it says why not.
    static func askCedric(_ editor: EditorViewController, window: UIWindow) async {
        let ready = AskCedricModel.chatSettings()
        log.append("INFO Ask Cedric engine: \(ready.map { AIStatus.backendTitle($0.backend) } ?? "none ready")")
        editor.askCedric()
        try? await Task.sleep(for: .seconds(1))
        guard let host = editor.presentedViewController as? UIHostingController<AskCedricView> else {
            check(false, "Ask Cedric sheet opened")
            return
        }
        check(true, "Ask Cedric sheet opened")
        let model = host.rootView.model
        guard ready != nil else {
            await model.prepare()
            check(model.unavailable != nil, "Ask Cedric explains no engine is ready")
            return
        }
        model.ask("What does this file do? Answer in one sentence.")
        for _ in 0..<240 where model.running { try? await Task.sleep(for: .milliseconds(250)) }
        let answer = model.entries.last { $0.role == .owl }?.text ?? ""
        let note = model.entries.last { $0.role == .note }?.text
        try? await Task.sleep(for: .milliseconds(300))
        // The sheet itself (a window snapshot leaves it blank on Mac Catalyst).
        host.view.layoutIfNeeded()
        let r = UIGraphicsImageRenderer(bounds: host.view.bounds)
        try? r.image { _ in _ = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            .pngData()?.write(to: outDir!.appendingPathComponent("iphone-light-ask-cedric-sheet.png"))
        check(!answer.isEmpty, "Ask Cedric answered (\(model.engineTitle ?? "?")): \(answer.prefix(120))\(note.map { " note: " + $0 } ?? "")")
        try? await Task.sleep(for: .milliseconds(500))
    }

    static func shot(_ window: UIWindow, _ browser: UIViewController, sample: String, sizeClass: UIUserInterfaceSizeClass,
                     name: String, _ body: (EditorViewController) async -> Void) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent(sample)
        try? FileManager.default.removeItem(at: url)
        if let src = Bundle.main.url(forResource: (sample as NSString).deletingPathExtension,
                                     withExtension: (sample as NSString).pathExtension, subdirectory: "Samples") {
            try? FileManager.default.copyItem(at: src, to: url)
        }
        let doc = TextDocument(fileURL: url)
        let opened = await withCheckedContinuation { c in doc.open { c.resume(returning: $0) } }
        check(opened, "\(name): opened \(sample)")
        guard opened else { return }
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .fullScreen
        nav.traitOverrides.horizontalSizeClass = sizeClass
        browser.present(nav, animated: false)
        try? await Task.sleep(for: .seconds(1.5))
        await body(editor)
        try? await Task.sleep(for: .milliseconds(500))
        render(window, outDir!.appendingPathComponent(name + ".png"))
        if let bar = editor.navigationController?.navigationBar {
            EditorBarStyle.renderNavigationBar(bar, to: outDir!.appendingPathComponent(name + "-navbar.png"))
        }
        if editor.presentedViewController != nil {
            await withCheckedContinuation { c in editor.dismiss(animated: false) { c.resume() } }
        }
        await withCheckedContinuation { c in doc.close { _ in c.resume() } }
        await withCheckedContinuation { c in browser.dismiss(animated: false) { c.resume() } }
    }

    static func render(_ window: UIWindow, _ url: URL) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let img = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? img.pngData()?.write(to: url)
    }
}
#endif
