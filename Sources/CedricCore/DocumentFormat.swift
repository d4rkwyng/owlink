import Foundation

/// How a document's text is written: its encoding (with or without a BOM),
/// whether that encoding is Owlink's guess, and its line endings (one kind,
/// or a mixed file's own breaks). Reload and Revert to Saved replace the
/// text as one undoable edit; their ⌘Z gives the old text back with the
/// whole of its old format, and their redo the reloaded file's, so a save
/// after either writes the text as that version was written. Before 0.6.1
/// only the line breaks came back: the encoding and BOM stayed the
/// reloaded version's, and a save after ⌘Z wrote the old text with them
/// (a BOM it never had, or without the one it had).
public struct DocumentFormat: Sendable, Equatable {
    public var encoding: TextEncoding
    public var encodingGuessed: Bool
    public var lineEnding: LineEnding
    /// A mixed file's own breaks (nil: every break is `lineEnding`).
    public var lineBreaks: LineBreaks?

    public init(encoding: TextEncoding, encodingGuessed: Bool = false, lineEnding: LineEnding, lineBreaks: LineBreaks? = nil) {
        self.encoding = encoding
        self.encodingGuessed = encodingGuessed
        self.lineEnding = lineEnding
        self.lineBreaks = lineBreaks
    }

    /// The bytes a save writes for `text` (LF-only, as a tab holds it):
    /// nil if a character can't be represented in `encoding`.
    public func encoded(_ text: String) -> Data? {
        TextCodec.encodeDocument(text, encoding: encoding, lineEnding: lineEnding, lineBreaks: lineBreaks)
    }
}
