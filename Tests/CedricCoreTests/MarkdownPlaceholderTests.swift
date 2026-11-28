import Foundation
import Testing
@testable import CedricCore

/// The inline pass keeps its code spans, links and escapes in a table and
/// leaves a private-use placeholder (U+E000 index U+E001) in the text. Text
/// the user typed can hold those same characters (and U+E002 / U+E003, the
/// hard-break and escaped-dollar marks): it must come out as typed, never be
/// read as a placeholder. v0.6.0 trapped on `\*` + U+E000 `-1` U+E001 (index
/// out of range) and recursed without end on a code span holding U+E000 `0`
/// U+E001; the live preview renders every Markdown document with this code.
@Suite struct MarkdownPlaceholderTests {
    static let o = "\u{E000}", c = "\u{E001}"

    @Test func aNegativeIndexAfterAnEscapeIsKept() {
        let html = Markdown.render("\\*\u{E000}-1\u{E001}\n")
        #expect(html.contains("*\u{E000}-1\u{E001}"), "got \(html)")
    }

    @Test func aPlaceholderLookalikeInACodeSpanIsKept() {
        let html = Markdown.render("`\u{E000}0\u{E001}`\n")
        #expect(html.contains("<code>\u{E000}0\u{E001}</code>"), "got \(html)")
    }

    @Test func lookalikesBesideRealPlaceholdersAreKept() {
        let html = Markdown.render("a `x` b \u{E000}0\u{E001} c \u{E000}99\u{E001} \u{E000}\u{E001} \u{E000}abc \u{E000}\n")
        #expect(html.contains("<code>x</code>"), "got \(html)")
        #expect(html.contains("b \u{E000}0\u{E001} c"), "got \(html)")
        #expect(html.contains("\u{E000}99\u{E001} \u{E000}\u{E001} \u{E000}abc \u{E000}"), "got \(html)")
    }

    @Test func aSelfReferencingSpanAcrossHeadingsLinksAndCells() {
        let weird = "\u{E000}0\u{E001}"
        let inputs = [
            "# `\(weird)`\n", "[`\(weird)`](http://a.b/c)\n", "![\(weird)](http://a.b/i.png)\n",
            "| h |\n| - |\n| `\(weird)` |\n", "- `\(weird)` \(weird)\n", "> `\(weird)`\n",
            "See[^1].\n\n[^1]: `\(weird)` \u{E000}-3\u{E001}\n", "`\(weird)` **\(weird)** ~~\(weird)~~ _\(weird)_\n",
        ]
        for s in inputs {
            let html = Markdown.render(s)
            #expect(html.contains(weird), "\(s.debugDescription) -> \(html)")
        }
    }

    @Test func theHardBreakAndDollarMarksOfTheUserAreText() {
        let html = Markdown.render("a\u{E002}  \nb\u{E002}\\\nc\n")
        #expect(html.contains("a\u{E002}<br>\nb\u{E002}<br>\nc"), "got \(html)")
        var options = Markdown.Options()
        options.math = true
        let m = Markdown.render("x\u{E003} \\$1 and $y$ \u{E003}\n", options: options)
        #expect(m.contains("x\u{E003} \\$1") || m.contains("x\u{E003} $1"), "got \(m)")
        #expect(m.contains("\u{E003}") && m.contains("math-inline"), "got \(m)")
    }

    @Test func anImageAltKeepsTheCharacters() {
        let html = Markdown.render("![a\u{E000}b\u{E001}c `x`](http://a.b/i.png)\n")
        #expect(html.contains("alt=\"a\u{E000}b\u{E001}c x\""), "got \(html)")
    }

    @Test func anEmbeddedNoteWithTheCharactersKeepsAllItsText() throws {
        let t = try makeTree(["n/doc.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let n = t.appendingPathComponent("n")
        try "before \u{E000} after `code` \u{E000}0\u{E001} end".write(to: n.appendingPathComponent("Child.md"), atomically: true, encoding: .utf8)
        let vault = WikiVault(documentFolder: n)
        let html = ob("`x` ![[Child]] `y` \u{E000}0\u{E001}\n", vault: vault)
        #expect(html.contains("before \u{E000} after <code>code</code> \u{E000}0\u{E001} end"), "got \(html)")
        #expect(html.contains("<code>x</code>") && html.contains("<code>y</code>"), "got \(html)")
    }

    // Whatever the mix, the render ends and keeps every private-use
    // character it was given.
    @Test func randomMixesNeverTrapAndKeepTheCharacters() {
        let pieces = ["\u{E000}", "\u{E001}", "\u{E002}", "\u{E003}", "0", "-1", "9999", "`", "``", "\\*", "\\", "**", "_", "[a](b)", "<b>", "http://a.b", "x", " ", "  \n", "\n", "|", "$"]
        var rng = SystemRandomNumberGenerator.Seeded(seed: 61)
        for round in 0..<3_000 {
            var s = ""
            for _ in 0..<Int.random(in: 1...30, using: &rng) { s += pieces.randomElement(using: &rng)! }
            var options = Markdown.Options(highlightCode: false, obsidian: round % 2 == 0)
            options.math = round % 3 == 0
            let html = Markdown.render(s, options: options)
            for mark in ["\u{E000}", "\u{E001}"] where s.contains(mark) && !s.contains("`") && !s.contains("\\") {
                #expect(html.contains(mark), "\(s.debugDescription) -> \(html)")
            }
        }
    }
}
