import UIKit
import WebKit
import PDFKit
import CedricCore

@MainActor
protocol CopyPasteboard {
    var changeCount: Int { get }
    func write(_ item: [String: Any])
}

@MainActor
struct SystemCopyPasteboard: CopyPasteboard {
    var changeCount: Int { UIPasteboard.general.changeCount }
    func write(_ item: [String: Any]) { UIPasteboard.general.items = [item] }
}

/// Markdown rendering kept off the main thread, on a thread of its own with
/// a main-thread-sized stack (as the Mac's MarkdownWork): rendering recurses
/// into nested lists and quotes, which can overflow a dispatch thread's
/// smaller stack on a deeply nested document.
enum MarkdownWork {
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T, then: @escaping @MainActor @Sendable (T) -> Void) {
        let thread = Thread {
            let result = work()
            DispatchQueue.main.async { MainActor.assumeIsolated { then(result) } }
        }
        thread.stackSize = 8 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}

@MainActor
enum MarkdownExportIOS {
    /// Copy as HTML: the rendered fragment. Like the Mac's, it makes no
    /// note-name index (the folder is not walked for `[[wikilinks]]`).
    static func renderFragment(markdown: String, folder: URL?, completion: @escaping @MainActor (String) -> Void) {
        let openedRoot = folder.flatMap { PreviewFolderGrants.shared.root(for: $0) }
        MarkdownWork.run({
            let vault = folder.map { WikiVault(documentFolder: $0, openedRoot: openedRoot) }
            return HTMLScrub.noScript(Markdown.render(markdown, options: .export(vault: vault)))
        }, then: completion)
    }

    static func renderPage(
        markdown: String,
        title: String,
        folder: URL?,
        remote: Bool = true,
        completion: @escaping @MainActor (String, URL?, URL?) -> Void
    ) {
        let openedRoot = folder.flatMap { PreviewFolderGrants.shared.root(for: $0) }
        struct Page: Sendable { let html: String; let vaultRoot: URL? }
        MarkdownWork.run({
            let vault = folder.map { WikiVault(documentFolder: $0, openedRoot: openedRoot) }
            if markdown.contains("[[") { vault?.prepareIndex() }
            let html = MarkdownExport.page(markdown: markdown, title: title, vault: vault, remote: remote)
            return Page(html: html, vaultRoot: vault?.root)
        }, then: { completion($0.html, openedRoot, $0.vaultRoot) })
    }

    /// A page: US Letter's proportions at the page's 760-point width (as
    /// the Mac's Markdown PDF export).
    static let pageWidth: CGFloat = 760
    static var pageHeight: CGFloat { (pageWidth * 11 / 8.5).rounded() }

    /// How a PDF was cut (for the checks): the page height, the block
    /// bottoms measured, and the cuts `PageBreaks` made from them.
    struct PDFLayout: Sendable {
        let total: CGFloat
        let bottoms: [CGFloat]
        let cuts: [CGFloat]
    }

    static func makePDF(
        html: String,
        folder: URL?,
        openedRoot: URL?,
        vaultRoot: URL?,
        completion: @escaping @MainActor (Result<Data, Error>) -> Void
    ) {
        makePagedPDF(html: html, folder: folder, openedRoot: openedRoot, vaultRoot: vaultRoot) { completion($0.map(\.0)) }
    }

    /// The PDF and how it was cut between blocks.
    static func makePagedPDF(
        html: String,
        folder: URL?,
        openedRoot: URL?,
        vaultRoot: URL?,
        completion: @escaping @MainActor (Result<(Data, PDFLayout), Error>) -> Void
    ) {
        MarkdownPDFJob.start(html: html, folder: folder, openedRoot: openedRoot, vaultRoot: vaultRoot, completion: completion)
    }

    /// The export web view's configuration: page JavaScript off, nothing
    /// kept, and only the document-folder scheme handler (no user scripts,
    /// no message handlers).
    static func exportConfiguration(files: PreviewFiles) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(files, forURLScheme: PreviewFolder.scheme)
        return configuration
    }

    /// Called with each export web view's configuration as it starts (for
    /// the checks only).
    static var probeConfiguration: ((WKWebViewConfiguration) -> Void)?

    /// The page's links into the app (`cedric-doc:`, as WebKit resolves a
    /// relative link against the page's base) made relative to `folder`,
    /// keeping a heading `#fragment`. On iOS the share sheet's destination
    /// isn't known yet, so this is the document's own folder: a copy saved
    /// beside the note keeps working links.
    static func relink(_ page: PDFPage, savedIn folder: URL) {
        for a in page.annotations {
            guard let u = a.url, u.scheme == PreviewFolder.scheme, let file = PreviewFolder.fileURL(for: u) else { continue }
            var rel = WikiVault.relativeHref(file, from: folder)
            if let f = u.fragment, !f.isEmpty { rel += "#" + f }
            a.url = URL(string: rel)
        }
    }
}

@MainActor
private final class MarkdownPDFJob: NSObject, WKNavigationDelegate {
    private static var running: [MarkdownPDFJob] = []
    private let webView: WKWebView
    private let files: PreviewFiles
    private let folder: URL?
    private let completion: @MainActor (Result<(Data, MarkdownExportIOS.PDFLayout), Error>) -> Void
    private var finished = false

    private init(
        folder: URL?,
        openedRoot: URL?,
        vaultRoot: URL?,
        completion: @escaping @MainActor (Result<(Data, MarkdownExportIOS.PDFLayout), Error>) -> Void
    ) {
        self.completion = completion
        self.folder = folder
        let files = PreviewFiles()
        self.files = files
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: MarkdownExportIOS.pageWidth, height: MarkdownExportIOS.pageHeight),
            configuration: MarkdownExportIOS.exportConfiguration(files: files)
        )
        super.init()
        webView.navigationDelegate = self
        webView.isHidden = true
        files.folder = folder
        files.openedRoot = openedRoot
        files.vaultRoot = vaultRoot
    }

    static func start(
        html: String,
        folder: URL?,
        openedRoot: URL?,
        vaultRoot: URL?,
        completion: @escaping @MainActor (Result<(Data, MarkdownExportIOS.PDFLayout), Error>) -> Void
    ) {
        let job = MarkdownPDFJob(folder: folder, openedRoot: openedRoot, vaultRoot: vaultRoot, completion: completion)
        running.append(job)
        MarkdownExportIOS.probeConfiguration?(job.webView.configuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak job] in
            job?.finish(.failure(ExportError.timedOut))
        }
        let html = laidOutAtPageWidth(html)
        if let folder, let pageURL = PreviewFolder.pageURL(for: folder) {
            job.files.pageHTML = html
            job.files.pageURL = pageURL
            job.webView.load(URLRequest(url: pageURL))
        } else {
            job.webView.loadHTMLString(html, baseURL: nil)
        }
    }

    /// The exported page has no viewport tag, so iOS would lay it out at
    /// a 980-pixel virtual width and scale it down; the PDF's copy (only)
    /// gets one, so the page is laid out at the web view's 760-point width
    /// as on the Mac, and block bottoms and slice rects share one scale.
    static func laidOutAtPageWidth(_ html: String) -> String {
        let tag = #"<meta name="viewport" content="width=device-width, initial-scale=1">"#
        guard !html.contains(#"name="viewport""#) else { return html }
        if let head = html.range(of: "<head>", options: .caseInsensitive) {
            return html.replacingCharacters(in: head, with: html[head] + tag)
        }
        return tag + html
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Let images settle a moment (as the Mac).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.measure() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    /// The page's height and its block bottoms, read once in the app's own
    /// content world (page JavaScript stays off), then cut with PageBreaks.
    private func measure() {
        guard !finished else { return }
        let h = MarkdownExportIOS.pageHeight
        let js = """
        const out = [], y = window.scrollY;
        for (const e of document.querySelectorAll('body > *, li, tr, pre')) { const r = e.getBoundingClientRect(); out.push(r.bottom + y); }
        return [document.documentElement.scrollHeight, out];
        """
        webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, !self.finished else { return }
                var total = h
                var bottoms: [CGFloat] = []
                if case .success(let v) = result, let a = v as? [Any] {
                    total = CGFloat((a.first as? NSNumber)?.doubleValue ?? Double(h))
                    bottoms = ((a.last as? [Any]) ?? []).compactMap { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } }
                }
                let cuts = PageBreaks.cuts(total: total, pageHeight: h, boundaries: bottoms)
                self.makePages(MarkdownExportIOS.PDFLayout(total: total, bottoms: bottoms, cuts: cuts))
            }
        }
    }

    /// One createPDF slice per page, joined; a short slice is padded so
    /// every page is the same size, content at the top.
    private func makePages(_ layout: MarkdownExportIOS.PDFLayout) {
        let cuts = layout.cuts
        let doc = PDFDocument()
        var k = 0
        @MainActor func next() {
            guard k + 1 < cuts.count else {
                guard doc.pageCount > 0 else { return finish(.failure(ExportError.noPages)) }
                guard let data = doc.dataRepresentation(), data.starts(with: Data("%PDF".utf8)) else {
                    return finish(.failure(ExportError.invalidPDF))
                }
                return finish(.success((data, layout)))
            }
            let y0 = cuts[k], y1 = cuts[k + 1]
            k += 1
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: y0, width: MarkdownExportIOS.pageWidth, height: y1 - y0)
            webView.createPDF(configuration: config) { [weak self] result in
                MainActor.assumeIsolated {
                    guard let self, !self.finished else { return }
                    guard case .success(let data) = result, let part = PDFDocument(data: data), let page = part.page(at: 0) else {
                        if case .failure(let e) = result { self.finish(.failure(e)) } else { self.finish(.failure(ExportError.invalidPDF)) }
                        return
                    }
                    let box = page.bounds(for: .mediaBox)
                    let full = MarkdownExportIOS.pageHeight
                    if box.height < full {
                        page.setBounds(CGRect(x: box.minX, y: box.maxY - full, width: box.width, height: full), for: .mediaBox)
                    }
                    if let folder = self.folder { MarkdownExportIOS.relink(page, savedIn: folder) }
                    doc.insert(page, at: doc.pageCount)
                    next()
                }
            }
        }
        next()
    }

    private func finish(_ result: Result<(Data, MarkdownExportIOS.PDFLayout), Error>) {
        guard !finished else { return }
        finished = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        completion(result)
        Self.running.removeAll { $0 === self }
    }

    private enum ExportError: LocalizedError {
        case timedOut
        case noPages
        case invalidPDF

        var errorDescription: String? {
            switch self {
            case .timedOut: return String(localized: "The PDF could not be made in time.")
            case .noPages: return String(localized: "The Markdown page has no printable content.")
            case .invalidPDF: return String(localized: "The PDF could not be created.")
            }
        }
    }
}
