import Foundation
import CedricCore

/// One request to open a file in the text editor from the document
/// browser, and what its retry and its failure do.
///
/// An editor-only open (the grid's Edit as Text, a crash-recovery restore,
/// a launch reopen) never puts a viewer file (a PDF, an Office or iWork
/// file) in the writable editor: not by its route when asked, not by the
/// bytes the coordinated read got, and not through "Open as Text", whose
/// retry is the same request with binary allowed (still editor-only).
struct EditorOpenRequest: Equatable {
    /// "Open as Text" was chosen: the editor's binary check is skipped.
    var binaryOK = false
    /// The grid's Edit as Text.
    var asText = false
    /// Unsaved text to put back (Restore at launch chosen).
    var recovered: RecoveryRecord?
    /// A launch reopen of the last document.
    var reopening = false

    /// Opens only the text editor (never a viewer), and never a viewer file.
    var editorOnly: Bool { asText || recovered != nil || reopening }

    /// The browser shows the file in its viewer when it routes to one.
    var mayShowViewer: Bool { !binaryOK && !editorOnly }

    /// The "Open as Text" retry: binary allowed, still editor-only.
    var openingAsText: EditorOpenRequest {
        var r = self
        r.binaryOK = true
        return r
    }

    /// Before the open: whether the file, as it is now, may open in the
    /// editor (an editor-only open of a viewer file may not).
    func mayOpenInEditor(_ url: URL) -> Bool {
        guard editorOnly else { return true }
        return DocumentViewerRoute.editorOnlyOpen(DocumentViewerRoute.route(for: url), reopening: reopening).opensEditor
    }

    /// The document to open: binary allowed as asked, and an editor-only
    /// open's read refuses viewer content (`TextDocument.refusesViewerContent`).
    func makeDocument(_ url: URL) -> TextDocument {
        let doc = TextDocument(fileURL: url)
        doc.openBinaryAnyway = binaryOK
        doc.refusesViewerContent = editorOnly
        return doc
    }

    /// What a failed open shows.
    enum FailedOpen: Equatable {
        /// Nothing (a launch reopen ends quietly).
        case quiet
        /// "Couldn't open …".
        case couldNotOpen
        /// "This looks like a binary file" with Open as Text.
        case offerOpenAsText
    }

    /// After `document`'s open failed. `fileLooksBinary`: the editor's
    /// binary check of the file now. An editor-only open whose read got a
    /// viewer file never offers Open as Text.
    func failedOpen(document: TextDocument, fileLooksBinary: @autoclosure () -> Bool) -> FailedOpen {
        if reopening { return .quiet }
        if editorOnly, !document.mayPresentInEditor { return .couldNotOpen }
        if !binaryOK, fileLooksBinary() { return .offerOpenAsText }
        return .couldNotOpen
    }
}
