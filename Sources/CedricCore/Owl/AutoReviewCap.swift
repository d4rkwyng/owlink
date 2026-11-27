import Foundation

/// When Cedric stops looking at a document on his own: over
/// `maxUTF8Bytes` of UTF-8 **or** over `maxLines` lines, whichever comes
/// first. Above the cap nothing automatic runs for that document: no AI
/// scheduler check (on open, save, idle or edit), no AI grammar pass, no
/// grammar or typo pop-up, and so no local model is loaded because the
/// file was opened. The user can still ask (Ask Cedric, Ask AI Now, Check
/// for Risks, Check Grammar with Cedric, a whole-file review) after a
/// confirmation that names the size.
///
/// This is not large mode (`LargeDocument`, 25 M UTF-16 units or a
/// 20,000-character line): that one is about the editor keeping up with
/// typing and pauses colouring and spell check too. This one only switches
/// off Cedric's automatic work, at a far lower size. "Turn On Anyway" for
/// large mode does not lift it.
///
/// Why these numbers (static, never asked of the engine: asking a model
/// for its context window can load it, and nothing automatic may load a
/// model because a file opened):
/// - A 730 KB, 6,132-line Pwnagotchi log froze a Mac with Cedric's
///   automatic work still on, far below large mode. Either threshold here
///   would have stopped it.
/// - Ordinary source files, notes and Markdown are well under 100 KB and
///   2,000 lines, so they keep their automatic hints.
/// - Hints only ever see an 8 KB window (`OwlContextWindow.byteCap`), so a
///   bigger file gains little from automatic AI and costs whole-file work
///   (copies, scans, model load) on the main thread around it.
/// - Bytes or lines: a dense 90 KB file of 5,000 short lines is capped,
///   and so is a 150 KB file of 400 long lines.
/// - 100 KB is 100,000 bytes, as Finder counts it, so "100 KB" in the
///   note means what the user sees in Finder.
public enum AutoReviewCap {
    /// More UTF-8 bytes than this: no automatic Cedric work.
    public static let maxUTF8Bytes = 100_000
    /// More lines than this (a final newline doesn't start another line):
    /// no automatic Cedric work.
    public static let maxLines = 2_000

    public enum Reason: String, Sendable, Equatable {
        case bytes, lines
    }

    /// A document's size, as the cap counts it.
    public struct Size: Sendable, Equatable {
        public var utf8Bytes: Int
        public var lines: Int
        public init(utf8Bytes: Int, lines: Int) {
            self.utf8Bytes = utf8Bytes
            self.lines = lines
        }
    }

    /// Why a document of this size is capped, or nil when it isn't. Exactly
    /// at a threshold is not over it.
    public static func reason(utf8Bytes: Int, lines: Int) -> Reason? {
        if utf8Bytes > maxUTF8Bytes { return .bytes }
        if lines > maxLines { return .lines }
        return nil
    }

    public static func reason(_ size: Size) -> Reason? { reason(utf8Bytes: size.utf8Bytes, lines: size.lines) }

    public static func isCapped(_ size: Size) -> Bool { reason(size) != nil }

    /// The same verdict without counting UTF-8 when it can't matter: a
    /// UTF-16 unit is 1 to 3 UTF-8 bytes (a surrogate pair is 4 for 2), so
    /// over the cap in UTF-16 units is over it in bytes, and a third of the
    /// cap or less never is. Only in between is `utf8Bytes` called. For
    /// every edit in the app: O(1) for most documents.
    public static func reason(utf16Length: Int, lines: Int, utf8Bytes: () -> Int) -> Reason? {
        if utf16Length > maxUTF8Bytes { return .bytes }
        if utf16Length * 3 > maxUTF8Bytes, utf8Bytes() > maxUTF8Bytes { return .bytes }
        if lines > maxLines { return .lines }
        return nil
    }

    /// Lines as a user counts them: "a\nb" and "a\nb\n" are 2, "" is 0.
    public static func lineCount(_ text: NSString) -> Int {
        lineCount(LineIndex(text))
    }

    /// The same from a line index (O(1)): its last line is empty after a
    /// final newline, and that one isn't counted.
    public static func lineCount(_ index: LineIndex) -> Int {
        guard index.length > 0 else { return 0 }
        let last = index.lineCount - 1
        return index.lineLength(last) == 0 ? last : index.lineCount
    }

    public static func size(of text: String) -> Size {
        let ns = text as NSString
        return Size(utf8Bytes: ns.lengthOfBytes(using: String.Encoding.utf8.rawValue), lines: lineCount(ns))
    }

    public static func reason(for text: String) -> Reason? { reason(size(of: text)) }

    // MARK: Wording

    /// "730 KB" (Finder's units), "6,132 lines".
    public static func describe(_ size: Size) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(size.utf8Bytes), countStyle: .file)
        let lines = size.lines.formatted(.number)
        return String(localized: "\(bytes), \(lines) lines")
    }

    /// The limits, in words: "100 KB or 2,000 lines".
    public static var limits: String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(maxUTF8Bytes), countStyle: .file)
        return String(localized: "\(bytes) or \(maxLines.formatted(.number)) lines")
    }

    /// The owl popover's quiet note for a capped document.
    public static func note(_ size: Size) -> String {
        String(localized: "Auto-review is off for large files (\(describe(size))). Cedric looks at this file only when you ask.")
    }

    /// The confirmation before a manual check of a capped document.
    public static func confirmation(fileName: String, size: Size) -> (title: String, message: String) {
        (String(localized: "Ask Cedric about this large file?"),
         String(localized: "“\(fileName)” is \(describe(size)). Cedric doesn’t review files over \(limits) on his own, so auto-review is off for it. Asking now sends what the check needs to the AI engine, which may take a while."))
    }
}
