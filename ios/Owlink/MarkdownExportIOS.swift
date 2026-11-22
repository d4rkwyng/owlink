import UIKit
import WebKit
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

    static func makePDF(
        html: String,
        folder: URL?,
        openedRoot: URL?,
        vaultRoot: URL?,
        completion: @escaping @MainActor (Result<Data, Error>) -> Void
    ) {
        MarkdownPDFJob.start(html: html, folder: folder, openedRoot: openedRoot, vaultRoot: vaultRoot, completion: completion)
    }
}

@MainActor
private final class MarkdownPDFJob: NSObject, WKNavigationDelegate {
    private static var running: [MarkdownPDFJob] = []
    private let webView: WKWebView
    private let files: PreviewFiles
    private let completion: @MainActor (Result<Data, Error>) -> Void
    private var finished = false

    private init(
        folder: URL?,
        openedRoot: URL?,
        vaultRoot: URL?,
        completion: @escaping @MainActor (Result<Data, Error>) -> Void
    ) {
        self.completion = completion
        let files = PreviewFiles()
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(files, forURLScheme: PreviewFolder.scheme)
        self.files = files
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 760, height: 980), configuration: configuration)
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
        completion: @escaping @MainActor (Result<Data, Error>) -> Void
    ) {
        let job = MarkdownPDFJob(folder: folder, openedRoot: openedRoot, vaultRoot: vaultRoot, completion: completion)
        running.append(job)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak job] in
            job?.finish(.failure(ExportError.timedOut))
        }
        if let folder, let pageURL = PreviewFolder.pageURL(for: folder) {
            job.files.pageHTML = html
            job.files.pageURL = pageURL
            job.webView.load(URLRequest(url: pageURL))
        } else {
            job.webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.renderPDF() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func renderPDF() {
        guard !finished else { return }
        let renderer = MarkdownPrintPageRenderer()
        let formatter = webView.viewPrintFormatter()
        formatter.perPageContentInsets = UIEdgeInsets(top: 36, left: 36, bottom: 36, right: 36)
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: 10_000))
        let pageCount = renderer.numberOfPages
        guard pageCount > 0 else {
            finish(.failure(ExportError.noPages))
            return
        }
        let bounds = renderer.paperRect
        let pdf = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            for page in 0..<pageCount {
                context.beginPage()
                renderer.drawPage(at: page, in: bounds)
            }
        }
        guard pdf.starts(with: Data("%PDF".utf8)) else {
            finish(.failure(ExportError.invalidPDF))
            return
        }
        finish(.success(pdf))
    }

    private func finish(_ result: Result<Data, Error>) {
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

@MainActor
private final class MarkdownPrintPageRenderer: UIPrintPageRenderer {
    override var paperRect: CGRect { CGRect(x: 0, y: 0, width: 612, height: 792) }
    override var printableRect: CGRect { paperRect.insetBy(dx: 36, dy: 36) }
}
