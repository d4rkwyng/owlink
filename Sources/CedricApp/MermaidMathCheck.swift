import AppKit
import CedricCore
import PDFKit
import WebKit

/// CEDRIC_CHECK=mermaidmath: Mermaid diagrams and KaTeX math in the
/// Markdown preview (PreviewRich). JavaScript off: the page is the one the
/// preview always drew (code and literal TeX, no script). On: an SVG per
/// good diagram, the error text in a bad one, KaTeX spans for math, every
/// resource from the bundled `cedric-asset:` files and none from the
/// network. A document without either loads nothing extra. The PDF export
/// follows the tab's Allow JavaScript.
@MainActor
extension DevChecks {
    static func mermaidMathCheck(_ app: AppDelegate) {
        let md = """
        # Diagrams and math

        Prices stay text: $5 and $10. Code stays code: `$x$`.

        Euler: $e^{i\\pi}+1=0$ inline.

        $$
        \\int_0^1 x^2\\,dx = \\frac{1}{3}
        $$

        ```mermaid
        graph TD
          Start --> Finish
        ```

        ```mermaid
        graph TD
          A --> --> B ((
        ```

        Last line.

        """
        let plain = "# Plain\n\nNo diagrams here, and $5 and $10 are prices.\n\n```swift\nlet a = 1\n```\n"
        let tab = app.open(write("rich.md", md))!
        let plainTab = app.open(write("plain.md", plain))!
        sized(tab); sized(plainTab)
        var offHTML = ""
        func p() -> PreviewController? { tab.preview }
        /// The page's own view (as page script sees it).
        func page(_ code: String, _ then: @escaping @MainActor (Any?) -> Void) { pageJS(tab, code, then) }
        /// Waits (up to 25 s) for the page's done mark.
        func waitDone(_ t: EditorWindowController, _ name: String) -> Step {
            { next in
                let deadline = Date().addingTimeInterval(25)
                @MainActor func poll() {
                    previewJS(t, "document.documentElement.getAttribute('\(PreviewRich.doneAttribute)')") { v in
                        if v as? String == "done" { expect(true, name); next() }
                        else if Date() > deadline { expect(false, name, "\(v ?? "nil")"); next() }
                        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { poll() } } }
                    }
                }
                poll()
            }
        }
        let expectedOff = PreviewController.page(body: Markdown.render(md, options: .preview(vault: nil)),
                                                 palette: tab.palette, csp: PreviewRich.csp(allowJavaScript: false, allowNetwork: false))
        // Records every Content-Security-Policy violation on the page (a
        // request to anywhere the policy doesn't name, the network included),
        // from Cedric's own content world, before any page script runs.
        let recorder = """
        document.documentElement.dataset.cspRecorder = '1';
        document.addEventListener('securitypolicyviolation', e => {
          const r = document.documentElement; r.dataset.cspViolations = (r.dataset.cspViolations || '') + e.violatedDirective + ' ' + e.blockedURI + '\\n';
        });
        """
        run([
            sync {
                focus(tab); if !tab.previewVisible { tab.togglePreview() }
                // (The preview exists now; the recorder runs from the next page load on.)
                expect(tab.preview != nil, "the preview is open")
                tab.preview?.webView.configuration.userContentController.addUserScript(
                    WKUserScript(source: recorder, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
            },
            waitForPreview(tab, contains: "Last line.", "the preview shows the document (JavaScript off)"),
            { next in
                page("[document.scripts.length, document.querySelectorAll('svg').length, document.querySelectorAll('.katex').length, document.querySelectorAll('pre > code.language-mermaid').length, document.documentElement.outerHTML.includes('cedric-asset'), document.body.innerText]") { v in
                    let a = v as? [Any] ?? []
                    let n = a.prefix(4).map { ($0 as? NSNumber)?.intValue ?? -1 }
                    let text = a.count > 5 ? a[5] as? String ?? "" : ""
                    expect(n == [0, 0, 0, 2] && (a.count > 4 ? (a[4] as? NSNumber)?.boolValue == false : false),
                           "JS off: no script, no SVG, no KaTeX, both mermaid blocks as code, no bundled file named", "\(a.prefix(5))")
                    expect(text.contains("$e^{i\\pi}+1=0$") && text.contains("$$") && text.contains("Start --> Finish"),
                           "JS off: math is literal text and the diagram its source")
                    next()
                }
            },
            sync {
                offHTML = p()?.lastPageHTML ?? ""
                expect(offHTML == expectedOff, "JS off: the page is byte for byte the page the preview always drew",
                       "\(offHTML.count) vs \(expectedOff.count) bytes")
                expect(p()?.assets.served.isEmpty == true && p()?.lastNeeds == [], "JS off: nothing served from the bundle",
                       "\(p()?.assets.served ?? [])")
                p()?.assets.resetLog()
            },
            snapshot("mermaidmath-off.png", window: tab.window),
            // JavaScript on.
            sync { tab.previewAllowsJavaScript = true },
            waitDone(tab, "JS on: the diagrams and math are drawn"),
            { next in
                page("""
                (() => { const pres = [...document.querySelectorAll('pre')].filter(p => p.querySelector('code.language-mermaid'));
                  return [pres.length, pres[0] ? pres[0].querySelectorAll('svg').length : -1, pres[1] ? pres[1].querySelectorAll('svg').length : -1,
                          pres[1] && pres[1].querySelector('.mermaid-error') ? pres[1].querySelector('.mermaid-error').textContent : '',
                          pres[0] ? pres[0].innerText : '', pres[0] && pres[0].hasAttribute('data-line') ? 1 : 0]; })()
                """) { v in
                    let a = v as? [Any] ?? []
                    let count = (a.first as? NSNumber)?.intValue ?? -1
                    let svg0 = a.count > 1 ? (a[1] as? NSNumber)?.intValue ?? -1 : -1
                    let svg1 = a.count > 2 ? (a[2] as? NSNumber)?.intValue ?? -1 : -1
                    let err = a.count > 3 ? a[3] as? String ?? "" : ""
                    let label = a.count > 4 ? a[4] as? String ?? "" : ""
                    expect(count == 2 && svg0 == 1, "JS on: the good mermaid block is an SVG", "\(a)")
                    expect(label.contains("Start") && label.contains("Finish"), "and it draws the diagram's labels", label)
                    expect(a.count > 5 && (a[5] as? NSNumber)?.intValue == 1, "the drawn block keeps its data-line")
                    expect(svg1 == 0 && err.hasPrefix("Mermaid: ") && err.count > 12, "JS on: the bad diagram shows its error, not a blank", err)
                    print("check: note: mermaid error text \(err.prefix(160).debugDescription)")
                    next()
                }
            },
            { next in
                page("""
                [document.querySelectorAll('.math-inline .katex').length, document.querySelectorAll('.math-display .katex-display').length,
                 document.body.innerText.includes('$5 and $10'), [...document.querySelectorAll('code')].some(c => c.textContent === '$x$'),
                 document.fonts.check('16px KaTeX_Main'), document.querySelectorAll('.katex-error').length]
                """) { v in
                    let a = v as? [Any] ?? []
                    let n = a.map { ($0 as? NSNumber)?.intValue ?? -1 }
                    expect(n.count == 6 && n[0] == 1 && n[1] == 1, "JS on: KaTeX spans for the inline and the display math", "\(n)")
                    expect(n.count == 6 && n[2] == 1 && n[3] == 1, "JS on: prices and the code span stay as typed", "\(n)")
                    expect(n.count == 6 && n[4] == 1 && n[5] == 0, "JS on: KaTeX's bundled font is loaded, no TeX error", "\(n)")
                    next()
                }
            },
            { next in
                // Every URL the page refers to for loading (scripts, style
                // sheets, images, SVG images and uses), every policy
                // violation (any blocked request, the network's included),
                // and the scheme handler's own log.
                page("""
                [[...document.querySelectorAll('script[src], link[href], img[src], iframe, source[src], image, use')]
                   .map(e => e.getAttribute('src') || e.getAttribute('href') || e.getAttribute('xlink:href') || '').filter(u => u && !u.startsWith('#')),
                 document.documentElement.dataset.cspViolations || '']
                """) { v in
                    let a = v as? [Any] ?? []
                    let urls = a.first as? [String] ?? []
                    let violations = a.count > 1 ? a[1] as? String ?? "?" : "?"
                    let served = p()?.assets.served ?? []
                    let refused = p()?.assets.refused ?? []
                    print("check: note: page URLs \(urls.count): \(urls.map { $0.replacingOccurrences(of: "cedric-asset://vendor/", with: "") }); handler served \(served.count)")
                    expect(urls.count == 4 && urls.allSatisfy { $0.hasPrefix("cedric-asset://vendor/") }, "JS on: every URL in the page is a bundled file, none from the network",
                           "\(urls)")
                    expect(violations.isEmpty, "JS on: no request was blocked by the policy (nothing tried the network)", violations)
                    expect(Set(served).isSuperset(of: [PreviewRich.mermaidScript, PreviewRich.katexScript, PreviewRich.katexStyle, PreviewRich.glueScript])
                           && served.contains { $0.hasSuffix(".woff2") } && refused.isEmpty,
                           "the asset handler served the scripts, style and fonts and refused nothing", "served \(served) refused \(refused)")
                    let html = p()?.lastPageHTML ?? ""
                    expect(html.contains("script-src 'unsafe-inline' cedric-doc: file: cedric-asset://vendor/katex/katex.min.js cedric-asset://vendor/mermaid/mermaid.min.js cedric-asset://vendor/owlink-rich.js; connect-src 'none'"),
                           "the page's policy names the bundled files, and connect-src stays 'none'")
                    expect(p()?.allowNetwork == false && (p()?.webView.configuration.userContentController != nil), "Allow Network is off (the block-all rule list is on)")
                    next()
                }
            },
            // The recorder works: a web image is blocked, and recorded.
            { next in
                previewJS(tab, "const i = document.createElement('img'); i.id = 'owlink-probe'; i.src = 'https://example.invalid/owlink-check.png'; document.body.appendChild(i); 1") { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        page("[document.documentElement.dataset.cspRecorder || '', document.documentElement.dataset.cspViolations || '']") { v in
                            let a = v as? [String] ?? []
                            let text = a.count > 1 ? a[1] : ""
                            expect(a.first == "1" && text.contains("img-src") && text.contains("example.invalid"),
                                   "a web image is blocked by the policy (the recorder sees it)", "\(a)")
                            previewJS(tab, "document.getElementById('owlink-probe')?.remove(); 1") { _ in }
                            next()
                        }
                    }
                }
            },
            snapshot("mermaidmath-on.png", window: tab.window),
            // Scrolling in step still finds the blocks.
            { next in
                tab.textView.scrollRangeToVisible(NSRange(location: (tab.text as NSString).length, length: 0))
                previewJS(tab, "window.__cedricLineAt ? window.__cedricLineAt(document.documentElement.scrollHeight) : -1") { v in
                    expect(((v as? NSNumber)?.doubleValue ?? -1) >= 10, "sync scrolling still reads the blocks' lines", "\(v ?? "nil")")
                    next()
                }
            },
            // A document with neither: nothing extra, even with JavaScript on.
            sync { focus(plainTab); if !plainTab.previewVisible { plainTab.togglePreview() } },
            waitForPreview(plainTab, contains: "are prices", "the plain document's preview"),
            sync { plainTab.previewAllowsJavaScript = true },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { next() } },
            { next in
                let html = plainTab.preview?.lastPageHTML ?? ""
                let expected = PreviewController.page(body: Markdown.render(plain, options: .preview(vault: nil)), palette: plainTab.palette,
                                                      csp: PreviewRich.csp(allowJavaScript: true, allowNetwork: false))
                expect(html == expected && !html.contains("cedric-asset"), "JS on, no diagram or math: the page as before, no bundled script",
                       "\(html.count) vs \(expected.count) bytes")
                expect(plainTab.preview?.assets.served.isEmpty == true, "and nothing is served", "\(plainTab.preview?.assets.served ?? [])")
                pageJS(plainTab, "document.scripts.length") { v in
                    expect((v as? NSNumber)?.intValue == 0, "and the page has no script", "\(v ?? "nil")")
                    next()
                }
            },
            // JavaScript off again: the code and the literal text are back.
            sync { focus(tab); tab.previewAllowsJavaScript = false },
            waitForPreview(tab, contains: "Start --> Finish", "JS off again: the source is back"),
            { next in
                page("[document.scripts.length, document.querySelectorAll('svg').length, document.querySelectorAll('.katex').length]") { v in
                    let n = (v as? [Any] ?? []).map { ($0 as? NSNumber)?.intValue ?? -1 }
                    expect(n == [0, 0, 0], "JS off again: no script, SVG or KaTeX", "\(n)")
                    expect(p()?.lastPageHTML == offHTML, "and the page is the JS-off page again")
                    next()
                }
            },
            // The bundle handler is shut with JavaScript off.
            sync { expect(p()?.assets.scriptOn == false, "JS off: the asset handler serves nothing") },
            // PDF export: follows the tab's Allow JavaScript.
            { next in
                let off = dir.appendingPathComponent("out/off.pdf"), on = dir.appendingPathComponent("out/on.pdf")
                try? FileManager.default.createDirectory(at: off.deletingLastPathComponent(), withIntermediateDirectories: true)
                let folder = tab.doc.fileURL?.deletingLastPathComponent()
                MarkdownPDFExport.run(markdown: md, folder: folder, title: "off", rich: false, to: off) { e1 in
                    MarkdownPDFExport.run(markdown: md, folder: folder, title: "on", rich: true, to: on) { e2 in
                        let t1 = PDFDocument(url: off)?.string ?? "", t2 = PDFDocument(url: on)?.string ?? ""
                        expect(e1 == nil && t1.contains("Start --> Finish") && t1.contains("$e^{i"), "PDF with JS off: diagram source and TeX as text",
                               String(t1.prefix(160)))
                        expect(e2 == nil && !t2.contains("Start --> Finish") && t2.contains("Start") && t2.contains("Finish") && !t2.contains("$e^{i")
                               && t2.contains("Mermaid: ") && t2.contains("$5 and $10"),
                               "PDF with JS on: the diagram and math drawn, the bad diagram's error shown", t2.debugDescription)
                        for (u, n) in [(off, "mermaidmath-off.pdf"), (on, "mermaidmath-on.pdf")] {
                            try? FileManager.default.removeItem(at: out.appendingPathComponent(n))
                            try? FileManager.default.copyItem(at: u, to: out.appendingPathComponent(n))
                        }
                        next()
                    }
                }
            },
            sync {
                // Exported HTML never carries script: the diagram stays code.
                let html = EditorWindowController.exportPage(markdown: md, title: "rich")
                expect(!html.contains("cedric-asset") && html.contains("language-mermaid") && !html.contains("math-inline"),
                       "exported HTML: no bundled script, the diagram's source and the TeX as typed")
                for t in [tab, plainTab] { t.doc.markSaved() }
                finish()
            },
        ])
    }
}
