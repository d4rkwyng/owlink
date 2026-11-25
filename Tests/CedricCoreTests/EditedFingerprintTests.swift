import Foundation
import Testing
@testable import CedricCore

/// EditedState for a long text: no copy of the saved text (chunk hashes
/// and the span edits touched), and the same dirty flag a copy gives.
@Suite struct EditedFingerprintTests {
    /// A storage stand-in: applies an edit and reports it as NSTextStorage
    /// does (the new range, the change in length), then the change.
    struct Buffer {
        let text: NSMutableString
        var state: EditedState
        init(_ s: String, limit: Int = 8, chunk: Int = 4) {
            text = NSMutableString(string: s)
            state = EditedState(savedText: nil, snapshotLimit: limit, chunk: chunk)
            state.saved(text)
        }
        mutating func replace(_ range: NSRange, with s: String) {
            text.replaceCharacters(in: range, with: s)
            let n = (s as NSString).length
            state.noteEdit(NSRange(location: range.location, length: n), delta: n - range.length)
            state.textChanged(to: text)
        }
    }

    @Test func aLongTextKeepsAFingerprintNotACopy() {
        let b = Buffer("0123456789abcdef")
        #expect(b.state.keepsFingerprint)
        let short = Buffer("0123", limit: 8)
        #expect(!short.state.keepsFingerprint)
        // The default limit: 16 M units.
        #expect(EditedState.snapshotLimit == 16 * 1024 * 1024)
    }

    @Test func typingThenUndoingIsCleanAgain() {
        var b = Buffer("hello world, a long saved text")
        b.replace(NSRange(location: 5, length: 0), with: "X")
        #expect(b.state.isDirty)
        b.replace(NSRange(location: 5, length: 1), with: "")
        #expect(!b.state.isDirty)
        // Same length, different text: dirty.
        b.replace(NSRange(location: 0, length: 1), with: "J")
        #expect(b.state.isDirty)
        b.replace(NSRange(location: 0, length: 1), with: "h")
        #expect(!b.state.isDirty)
    }

    /// An edit at one end and its undo at the other, a delete then an
    /// insert of other text at the same place, a whole replacement and its
    /// undo, an edit straddling chunk edges.
    @Test func spansFollowEditsAnywhere() {
        var b = Buffer("abcdefghijklmnopqrstuvwxyz0123456789")
        b.replace(NSRange(location: 0, length: 0), with: "<")
        b.replace(NSRange(location: 37, length: 0), with: ">")
        #expect(b.state.isDirty)
        b.replace(NSRange(location: 0, length: 1), with: "")
        #expect(b.state.isDirty)
        b.replace(NSRange(location: 36, length: 1), with: "")
        #expect(!b.state.isDirty)
        b.replace(NSRange(location: 10, length: 1), with: "")
        b.replace(NSRange(location: 10, length: 0), with: "K")
        #expect(b.state.isDirty)
        b.replace(NSRange(location: 10, length: 1), with: "k")
        #expect(!b.state.isDirty)
        b.replace(NSRange(location: 0, length: 36), with: "")
        #expect(b.state.isDirty)
        b.replace(NSRange(location: 0, length: 0), with: "abcdefghijklmnopqrstuvwxyz0123456789")
        #expect(!b.state.isDirty)
        b.replace(NSRange(location: 3, length: 6), with: "DEFGHI")
        #expect(b.state.isDirty)
        b.replace(NSRange(location: 3, length: 6), with: "defghi")
        #expect(!b.state.isDirty)
    }

    /// Saving makes the current text the baseline; going back to the
    /// previous saved text is then an edit. Reverting (the saved text set
    /// again, then rebased) is clean.
    @Test func saveAndRevert() {
        var b = Buffer("first saved version of the text")
        b.replace(NSRange(location: 0, length: 5), with: "THIRD")
        #expect(b.state.isDirty)
        b.state.saved(b.text)                         // ⌘S
        #expect(!b.state.isDirty && b.state.keepsFingerprint)
        b.replace(NSRange(location: 0, length: 5), with: "first")
        #expect(b.state.isDirty)                      // back to the old file: unsaved now
        b.replace(NSRange(location: 0, length: 5), with: "THIRD")
        #expect(!b.state.isDirty)
        b.replace(NSRange(location: 6, length: 5), with: "")
        #expect(b.state.isDirty)
        // Revert to Saved: the saved text replaces the buffer, then the rebase.
        b.replace(NSRange(location: 0, length: b.text.length), with: "THIRD saved version of the text")
        b.state.saved(b.text)
        #expect(!b.state.isDirty)
        // Format changes and forced stay as they were.
        b.state.noteFormatChange()
        #expect(b.state.isDirty)
        b.state.saved(b.text)
        b.state.forceDirty()
        #expect(b.state.isDirty)
    }

    /// A fingerprint made elsewhere (off the main thread) is the baseline.
    @Test func aPreparedFingerprintIsTheBaseline() {
        let text = NSMutableString(string: "prepared while the file opened")
        var s = EditedState(savedText: nil, snapshotLimit: 8, chunk: 4)
        #expect(s.isDirty == false)
        s.textChanged(to: text)
        #expect(s.isDirty)                            // nothing saved yet
        s.saved(fingerprint: TextFingerprint(text, chunk: 8))
        #expect(!s.isDirty && s.keepsFingerprint)
        text.replaceCharacters(in: NSRange(location: 0, length: 8), with: "PREPARED")
        s.noteEdit(NSRange(location: 0, length: 8), delta: 0)
        s.textChanged(to: text)
        #expect(s.isDirty)
        text.replaceCharacters(in: NSRange(location: 0, length: 8), with: "prepared")
        s.noteEdit(NSRange(location: 0, length: 8), delta: 0)
        s.textChanged(to: text)
        #expect(!s.isDirty)
    }

    /// Random edits (and returns to the saved text) against the copy
    /// EditedState keeps for short texts: the same flag after every edit.
    @Test func randomEditsAgreeWithACopy() {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("ab\né")
        for chunk in [4, 8, 64] {
            for _ in 0..<200 {
                let saved = String((0..<Int.random(in: 9..<60, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
                var b = Buffer(saved, limit: 8, chunk: chunk)
                var copy = EditedState(savedText: saved, snapshotLimit: Int.max)
                for _ in 0..<30 {
                    let len = b.text.length
                    if Int.random(in: 0..<5, using: &rng) == 0 {
                        // Back to the saved text by one replacement of the changed middle.
                        b.replace(NSRange(location: 0, length: len), with: saved)
                    } else {
                        let at = Int.random(in: 0...len, using: &rng)
                        let cut = Int.random(in: 0...min(3, len - at), using: &rng)
                        let ins = String((0..<Int.random(in: 0...3, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
                        b.replace(NSRange(location: at, length: cut), with: ins)
                    }
                    copy.textChanged(to: b.text)
                    #expect(b.state.isDirty == copy.isDirty, "saved \(saved.debugDescription) now \((b.text as String).debugDescription)")
                    #expect(b.state.isDirty == !(b.text as String == saved))
                }
            }
        }
    }

    @Test func hashesTellChunksApart() {
        let a = TextFingerprint("abcdefgh" as NSString, chunk: 4)
        #expect(a.hashes.count == 2 && a.hashes[0] != a.hashes[1])
        #expect(TextFingerprint("abcdefgh" as NSString, chunk: 4) == a)
        #expect(TextFingerprint("abcdefgi" as NSString, chunk: 4).hashes[1] != a.hashes[1])
        // Same units, other order or count.
        #expect(TextFingerprint("ba" as NSString, chunk: 4).hashes != TextFingerprint("ab" as NSString, chunk: 4).hashes)
        #expect(TextFingerprint("a" as NSString, chunk: 4).hashes != TextFingerprint("a\u{0}" as NSString, chunk: 4).hashes)
        let long = String(repeating: "x", count: 100)
        var other = Array(long.utf16)
        other[70] = 0x79
        #expect(TextFingerprint(long as NSString, chunk: 64).hashes[1] != TextFingerprint(String(decoding: other, as: UTF16.self) as NSString, chunk: 64).hashes[1])
        #expect(TextFingerprint("" as NSString).hashes.isEmpty)
    }
}
