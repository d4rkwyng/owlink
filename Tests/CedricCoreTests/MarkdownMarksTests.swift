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

    @Test func aFencedOrIndentedLineKeepsWhatFollowsATab() {
        #expect(Markdown.render("  ```\n\tx\n  ```\n").contains("<code>x\n</code>"))
        #expect(Markdown.render("    a\n\tb\n").contains("<code>a\nb\n</code>"))
    }

    @Test func inlineChoosesItsMarksFromItsText() {
        #expect(Markdown.inline("`\u{E000}0\u{E001}` \u{E000}0\u{E001} **b**") == "<code>\u{E000}0\u{E001}</code> \u{E000}0\u{E001} <strong>b</strong>")
    }
}
