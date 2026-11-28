import Foundation
import Testing
@testable import CedricCore

/// The renderer's internal marks are chosen per render from private-use
/// characters the text does not have (MarkdownRenderer.Marks).
@Suite struct MarkdownMarksTests {
    typealias Marks = MarkdownRenderer.Marks

    @Test func aDocumentWithoutTheCharactersUsesTheStandardMarks() {
        for text in ["plain `x` **y** \u{F8FF}\u{10FFFD}", "plain `x` **y** é 😀", ""] {
            let (m, exhausted) = Marks.choose(for: text, excluding: [])
            #expect(m == .standard && !exhausted, "\(text.debugDescription)")
        }
    }

    @Test func marksSkipTheCharactersOfTheDocumentInOrder() {
        let (m, exhausted) = Marks.choose(for: "a\u{E000}b\u{E002}c\u{E005}", excluding: [0xE003])
        #expect(!exhausted)
        #expect(m == Marks(open: "\u{E001}", close: "\u{E004}", brk: "\u{E006}", dollar: "\u{E007}"))
        // Past the first block: plane 15.
        var all = ""
        for v in 0xE000...0xF8FF { all.unicodeScalars.append(Unicode.Scalar(v)!) }
        #expect(Marks.choose(for: all, excluding: []).marks.open == "\u{F0000}")
    }

    @Test func aDocumentUsingEveryStandardMarkStillRendersAllItsParts() {
        var options = Markdown.Options(obsidian: true)
        options.math = true
        let html = Markdown.render("\u{E000}\u{E001}\u{E002}\u{E003} `c` [l](http://a.b) **s** ==h== a  \nb \\$1 $x$\n", options: options)
        #expect(html.hasPrefix("<p data-line=\"0\">\u{E000}\u{E001}\u{E002}\u{E003} <code>c</code> <a href=\"http://a.b\">l</a> <strong>s</strong> <mark>h</mark> a<br>\nb $1 <span class=\"math math-inline\">x</span></p>"), "got \(html)")
        // No mark of this render is left in the page.
        let m = Marks.choose(for: "\u{E000}\u{E001}\u{E002}\u{E003}", excluding: []).marks
        #expect(!html.unicodeScalars.contains(where: m.contains), "got \(html.debugDescription)")
    }

    @Test func anEmbeddedNoteHoldingTheParentsMarksRestartsCleanly() throws {
        let t = try makeTree(["n/doc.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let n = t.appendingPathComponent("n")
        // The parent has no private-use characters (standard marks); the
        // child has all four, as placeholders, a break and a dollar would be.
        try "c \u{E000}0\u{E001} \u{E002} \\\u{E003} `k`".write(to: n.appendingPathComponent("Child.md"), atomically: true, encoding: .utf8)
        let vault = WikiVault(documentFolder: n)
        var options = Markdown.Options.preview(vault: vault)
        options.math = true
        let html = Markdown.render("`x` \\$2 $y$ ![[Child]] **b** a  \nz\n", options: options)
        #expect(html.contains("c \u{E000}0\u{E001} \u{E002} \\\u{E003} <code>k</code>"), "got \(html)")
        #expect(html.contains("<code>x</code> $2 <span class=\"math math-inline\">y</span>") && html.contains("<strong>b</strong> a<br>\nz"), "got \(html)")
        #expect(!html.contains("\u{FFFD}"), "got \(html)")
        // The same as the child's text without the characters, but for them.
        try "c 0  \\ `k`".write(to: n.appendingPathComponent("Child.md"), atomically: true, encoding: .utf8)
        let plain = Markdown.render("`x` \\$2 $y$ ![[Child]] **b** a  \nz\n", options: options)
        #expect(html.replacingOccurrences(of: "\u{E000}", with: "").replacingOccurrences(of: "\u{E001}", with: "")
            .replacingOccurrences(of: "\u{E002}", with: "").replacingOccurrences(of: "\u{E003}", with: "") == plain)
    }

    @Test func noFreeMarkLeftScrubsTheDocumentsOwnAsALastResort() {
        // A pool of four, two of them in the text: two marks must come from it.
        let html = MarkdownRenderer(options: .init(), pool: [0xE000...0xE003]).render("`a` \u{E000}0\u{E001} b  \nc\n")
        #expect(html == "<p data-line=\"0\"><code>a</code> \u{FFFD}0\u{FFFD} b<br>\nc</p>\n", "got \(html.debugDescription)")
    }

    @Test func anEmbeddedNoteThatExhaustsThePoolIsScrubbed() throws {
        let t = try makeTree(["n/doc.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let n = t.appendingPathComponent("n")
        try "c \u{E000}0\u{E001} `k`".write(to: n.appendingPathComponent("Child.md"), atomically: true, encoding: .utf8)
        let vault = WikiVault(documentFolder: n)
        // Pool of five: after the restart only E002…E004 are free, so one
        // mark is a character of the note, which becomes U+FFFD there.
        let html = MarkdownRenderer(options: .preview(vault: vault), pool: [0xE000...0xE004]).render("`x` ![[Child]] **b**\n")
        #expect(html.contains("<code>x</code>") && html.contains("<strong>b</strong>") && html.contains("<code>k</code>"), "got \(html)")
        #expect(html.contains("c \u{FFFD}0\u{E001}") || html.contains("c \u{E000}0\u{FFFD}"), "got \(html)")
    }

    /// Every scalar of `ranges`, in order.
    static func scalars(_ ranges: ClosedRange<UInt32>...) -> String {
        var s = String.UnicodeScalarView()
        for r in ranges { for v in r { s.append(Unicode.Scalar(v)!) } }
        return String(s)
    }

    @Test func aTextWithEveryPrivateUseCharacterIsKeptWhole() {
        let all = Self.scalars(0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD)
        let (m, exhausted) = Marks.choose(for: all, excluding: [])
        // Not a letter (U+0100 is Ā): the first unassigned scalars.
        #expect(!exhausted && m == Marks(open: "\u{378}", close: "\u{379}", brk: "\u{380}", dollar: "\u{381}"))
        let more = Marks.choose(for: all + Self.scalars(0x100...0x37F), excluding: []).marks
        #expect(more == Marks(open: "\u{380}", close: "\u{381}", brk: "\u{382}", dollar: "\u{383}"))
        let html = Markdown.render("`c` \(all) **b** a  \nz\n")
        #expect(html == "<p data-line=\"0\"><code>c</code> \(all) <strong>b</strong> a<br>\nz</p>\n", "\(html.count) characters")
    }

    @Test func marksAreNeverJoiningCharacters() {
        // Joining, whitespace, or a letter, digit, punctuation or symbol.
        for v: UInt32 in [0x301, 0x200D, 0x600, 0x1F1E6, 0x1100, 0x3000, 0x2028, 0xFE0F, 0x100, 0x4E00, 0x660, 0x2014, 0x1F600] {
            #expect(!Marks.usable(v), "U+\(String(v, radix: 16))")
        }
        for v: UInt32 in [0xE000, 0xF8FF, 0xF0000, 0x10FFFD, 0x378, 0xFFFF, 0x10FFFF, 0x40000] {
            #expect(Marks.usable(v), "U+\(String(v, radix: 16))")
        }
    }

    // Each restart excludes every character of the colliding text: one
    // restart per note, and nothing lost while free marks are left.
    @Test func notesHoldingSuccessiveMarksAreAllKept() throws {
        let t = try makeTree(["n/doc.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let n = t.appendingPathComponent("n")
        func group(_ k: Int) -> String { Self.scalars(UInt32(0xE000 + 4 * k)...UInt32(0xE003 + 4 * k)) }
        for k in 0..<65 { try "note \(group(k)) `k`".write(to: n.appendingPathComponent("N\(k).md"), atomically: true, encoding: .utf8) }
        let vault = WikiVault(documentFolder: n)
        let eight = Markdown.render((0..<8).map { "![[N\($0)]]" }.joined(separator: " ") + " `x`\n", options: .preview(vault: vault))
        for k in 0..<8 { #expect(eight.contains("note \(group(k)) <code>k</code>"), "N\(k): \(eight)") }
        #expect(!eight.contains("\u{FFFD}"))
        // Only past the restart cap is a note's mark scrubbed: the 64th.
        let all = Markdown.render((0..<65).map { "![[N\($0)]]" }.joined(separator: " ") + " `x`\n", options: .preview(vault: vault))
        for k in 0..<65 where k != MarkdownRenderer.maxAttempts - 1 {
            #expect(all.contains("note \(group(k)) <code>k</code>"), "N\(k)")
        }
        #expect(all.contains("note \u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD} <code>k</code>") && all.contains("<code>x</code>"))
    }

    @Test func inlineChoosesItsMarksFromItsText() {
        #expect(Markdown.inline("`\u{E000}0\u{E001}` \u{E000}0\u{E001} **b**") == "<code>\u{E000}0\u{E001}</code> \u{E000}0\u{E001} <strong>b</strong>")
    }
}
