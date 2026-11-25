import AppKit
import CedricCore

/// `CEDRIC_CHECK=cert` (tools-check): certificates made on the spot with
/// /usr/bin/openssl, opened in the running app. A PEM file (a key, a
/// certificate and its CA) opens in the editor with the Certificate
/// panel beside it (key not shown, chain listed, expiry badge); ⌥⌘P
/// hides and shows it; an edit re-renders it; a pasted certificate in an
/// untitled tab can show it. A DER certificate and a PKCS#7 bundle open
/// in read-only certificate tabs; View as PEM Text opens the PEM.
@MainActor
extension DevChecks {
    static func ssl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    static func certificateCheck(_ app: AppDelegate) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") else {
            expect(false, "openssl available", "/usr/bin/openssl missing"); finish(); return
        }
        ssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-days", "365",
             "-subj", "/CN=Check CA/O=Cedric Check", "-addext", "basicConstraints=critical,CA:TRUE"])
        ssl(["req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "site.key", "-out", "site.csr", "-subj", "/CN=site.check"])
        ssl(["x509", "-req", "-in", "site.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-out", "site.pem", "-days", "20"])
        ssl(["x509", "-in", "site.pem", "-outform", "DER", "-out", "site.der"])
        ssl(["crl2pkcs7", "-nocrl", "-certfile", "site.pem", "-certfile", "ca.pem", "-outform", "DER", "-out", "chain.p7b"])
        func read(_ n: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8)) ?? "" }
        let bundle = read("site.key") + read("site.pem") + read("ca.pem")
        let pemURL = write("bundle.pem", bundle)

        // The clipboard and the remembered panel state are put back at the end.
        let savedClipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        let savedClosed = UserDefaults.standard.object(forKey: "certificatePanelClosed")
        CertificatePanel.closedByUser = false
        func restore() {
            NSPasteboard.general.clearContents()
            if !savedClipboard.isEmpty { NSPasteboard.general.writeObjects(savedClipboard) }
            UserDefaults.standard.set(savedClosed, forKey: "certificatePanelClosed")
        }
        var clip: String? { NSPasteboard.general.string(forType: .string) }
        /// A click on the panel's nth Copy link labelled `label`, through NSTextView's link handling.
        func clickCopy(_ d: CertificateDetailsView?, _ label: String, _ nth: Int = 0) -> Bool {
            guard let d, let i = d.copyIndex(label, nth), let storage = d.textView.textStorage else { return false }
            var at: Int?
            storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { v, r, stop in
                if (v as? URL)?.absoluteString == "\(CertificateDetailsView.copyScheme)://\(i)" { at = r.location; stop.pointee = true }
            }
            guard let at, let link = storage.attribute(.link, at: at, effectiveRange: nil) else { return false }
            NSPasteboard.general.clearContents()
            d.textView.clicked(onLink: link, at: at)
            return true
        }
        let siteBlock = read("site.pem").trimmingCharacters(in: .newlines)
        let caBlock = read("ca.pem").trimmingCharacters(in: .newlines)

        guard let tab = app.open(pemURL) else { expect(false, "bundle.pem opens as text"); restore(); finish(); return }
        sized(tab)
        var panel: CertificatePanel? { tab.previewPane?.renderer as? CertificatePanel }
        var shown: String { panel?.details.renderedText ?? "" }
        var renders = 0
        var der: CertificateTabController?
        var p7b: CertificateTabController?
        var untitled: EditorWindowController?

        func waitRender(_ name: String, after: @escaping () -> Int, panelOf: @escaping () -> CertificatePanel?) -> (@escaping () -> Void) -> Void {
            { next in
                let start = after()
                let deadline = Date().addingTimeInterval(5)
                @MainActor func poll() {
                    if let p = panelOf(), p.renders > start { expect(true, name); next() }
                    else if Date() > deadline { expect(false, name, "no render (\(panelOf()?.renders ?? -1))"); next() }
                    else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } } }
                }
                poll()
            }
        }

        var steps: [Step] = []
        let steps1: [Step] = [
            sync { focus(tab) },
            waitRender("the Certificate panel opens beside a PEM file and renders", after: { 0 }, panelOf: { panel }),
            sync {
                expect(tab.previewPane?.titleLabel.stringValue == "Certificate", "its header says Certificate",
                       tab.previewPane?.titleLabel.stringValue ?? "-")
                expect(tab.textView.isEditable && tab.text == bundle, "the text stays in the editor, editable")
                expect(shown.contains("Private key — not shown"), "the private key is named, not shown", String(shown.prefix(200)))
                expect(!shown.contains(read("site.key").split(separator: "\n")[1]), "no key material in the panel")
                expect(shown.contains("1 of 2: site.check") && shown.contains("2 of 2: Check CA"), "the chain is listed in order")
                expect(shown.contains("Expires in 19 days") || shown.contains("Expires in 20 days"), "the leaf's expiry badge",
                       String(shown.prefix(400)))
                expect(shown.contains("Issued by\tCN=Check CA, O=Cedric Check"), "issuer in plain words")
                expect(shown.contains("Certificate authority\tYes"), "the CA says so")
                expect(shown.contains("SHA-256\t"), "fingerprints shown")
            },
            snapshot("cert-panel.png"),
            sync {
                // The text is the file's, whole: ⌘A ⌘C copies it exactly.
                focus(tab)
                key("a", [.command])
                NSPasteboard.general.clearContents()
                key("c", [.command])
                let file = (try? Data(contentsOf: pemURL)) ?? Data()
                expect(clip.map { Data($0.utf8) } == file, "⌘A ⌘C copies the PEM text byte for byte",
                       "\(clip?.utf8.count ?? -1) vs \(file.count) bytes")
                tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
                // The panel's Copy links.
                let d = panel?.details
                expect(clickCopy(d, "pem", 0) && clip == siteBlock, "Copy Certificate (PEM) copies exactly the first block",
                       String((clip ?? "-").suffix(40)))
                expect(clickCopy(d, "pem", 1) && clip == caBlock, "and the second one its own block")
                expect(clickCopy(d, "Subject") && clip == "CN=site.check", "Copy subject", clip ?? "-")
                expect(clickCopy(d, "Issued by") && clip == "CN=Check CA, O=Cedric Check", "Copy issuer", clip ?? "-")
                let info = d?.items.compactMap(\.certificate).first
                expect(clickCopy(d, "SHA-256") && clip == info?.sha256 && clip?.count == 95, "Copy SHA-256 fingerprint", clip ?? "-")
                expect(clickCopy(d, "Serial number") && clip == info?.serialNumber, "Copy serial", clip ?? "-")
                expect(tab.text == bundle && !tab.doc.isDirty, "copying never touches the text")
            },
            sync {
                key("p", [.command, .option])
                expect(tab.previewPane == nil && CertificatePanel.closedByUser, "⌥⌘P hides the panel, and that is remembered")
                let other = app.open(write("again.pem", read("ca.pem")))
                TypingCheck.settle(0.3)
                expect(other?.previewPane == nil && other?.text == read("ca.pem"), "the next certificate file opens as text only")
                other?.window?.close()
                focus(tab)
                key("p", [.command, .option])
                expect(panel != nil && !CertificatePanel.closedByUser, "⌥⌘P shows it again (remembered too)")
                renders = panel?.renders ?? 0
            },
            waitRender("it renders again", after: { renders }, panelOf: { panel }),
            sync {
                // An edit: the CA's block broken, then the panel follows.
                renders = panel?.renders ?? 0
                let ns = tab.text as NSString
                let caStart = ns.range(of: "-----BEGIN CERTIFICATE-----", options: .backwards).location
                tab.textView.setSelectedRange(NSRange(location: caStart, length: 0))
                tab.textView.insertText("x", replacementRange: NSRange(location: caStart, length: 5))
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            waitRender("an edit re-renders the panel", after: { renders }, panelOf: { panel }),
            sync {
                expect(shown.contains("site.check") && !shown.contains("Check CA\n") && !shown.contains("2 of 2"),
                       "the broken block is gone from the list", String(shown.prefix(300)))
                tab.textView.undoManager?.undo()
                tab.doc.markSaved()
                // A DER certificate: its own read-only tab.
                let before = app.certificateTabs.count
                let r = app.open(dir.appendingPathComponent("site.der"))
                der = app.certificateTabs.last
                expect(r == nil && app.certificateTabs.count == before + 1, "a .der file opens in a certificate tab")
                if let w = der?.window { w.setContentSize(NSSize(width: 1000, height: 640)); w.makeKeyAndOrderFront(nil) }
                let t = der?.details.renderedText ?? ""
                expect(t.hasPrefix("site.check") && t.contains("Expires in"), "with its details and badge", String(t.prefix(200)))
                expect(app.currentTab == nil && app.currentViewerTab === der, "it is a viewer: the editor's commands are off")
            },
            snapshot("cert-der-tab.png"),
            sync {
                guard let der else { return }
                NSPasteboard.general.clearContents()
                press(der.copyPEMButton)
                expect(clip == read("site.pem"), "Copy as PEM: BEGIN/END lines, 64 columns, byte for byte as openssl writes it",
                       String((clip ?? "-").prefix(70)))
                expect(clickCopy(der.details, "pem", 0) && clip == read("site.pem"), "the tab's Copy Certificate (PEM) too")
                expect(clickCopy(der.details, "Subject") && clip == "CN=site.check", "and its field Copy links")
            },
            sync {
                let count = app.tabs.count
                guard let der else { return }
                press(der.pemButton)
                untitled = app.tabs.count == count + 1 ? app.tabs.last : nil
                let want = PEM.encode(der.items.first?.certificate?.der ?? Data())
                expect(untitled?.text == want && untitled?.doc.fileURL == nil, "View as PEM Text opens the PEM in a new tab",
                       String((untitled?.text ?? "-").prefix(80)))
                expect(untitled?.previewApplies == true, "and the panel applies to it")
                untitled?.togglePreview()
            },
            waitRender("the panel renders for the untitled PEM tab", after: { 0 }, panelOf: { untitled?.previewPane?.renderer as? CertificatePanel }),
            sync {
                untitled?.doc.markSaved()
                untitled?.window?.close()
                // A PKCS#7 bundle: both certificates.
                app.open(dir.appendingPathComponent("chain.p7b"))
                p7b = app.certificateTabs.last
                let t = p7b?.details.renderedText ?? ""
                expect(p7b !== der && t.contains("1 of 2") && t.contains("2 of 2") && t.contains("Check CA"), "a .p7b lists its certificates",
                       String(t.prefix(200)))
                expect(p7b?.statusBar.position.stringValue == "2 certificates (PKCS#7)", "status bar names the bundle",
                       p7b?.statusBar.position.stringValue ?? "-")
                // A plain text file without a certificate: no panel.
                let plain = app.open(write("notes.txt", "Just notes.\n"))
                expect(plain?.previewApplies == false, "an ordinary .txt has no Certificate panel")
                plain?.window?.close()
                restore()
                expect(UserDefaults.standard.object(forKey: "certificatePanelClosed") as? Bool == savedClosed as? Bool,
                       "the clipboard and the panel setting are put back")
            },
        ]
        steps += steps2
        run(steps)
    }
}
