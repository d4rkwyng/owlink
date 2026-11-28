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

    // Sol r1 on the first fix: the characters are part of the text, so
    // anything that reads the text (reference labels, titles, URLs, vault
    // names) must see them as typed.
    @Test func definitionTitlesAndDestinationsKeepTheCharacters() {
        let html = Markdown.render("`x` [label][r]\n\n[r]: /page \"a\u{E000}0\u{E001}b\u{E002}c\"\n")
        #expect(html.contains("title=\"a\u{E000}0\u{E001}b\u{E002}c\""), "got \(html)")
        #expect(html.contains("<code>x</code>"), "got \(html)")
    }

    @Test func referenceAndFootnoteLabelsMatchWithTheCharacters() {
        let fn = Markdown.render("See[^n\u{E001}].\n\n[^n\u{E001}]: body\n")
        #expect(fn.contains("footnote") && fn.contains("body"), "got \(fn)")
        let ref = Markdown.render("[label][r\u{E001}]\n\n[r\u{E001}]: /page\n")
        #expect(ref.contains("<a href=\"/page\">label</a>"), "got \(ref)")
    }

    @Test func aBareURLIsOneAnchorWithTheCharacters() {
        let html = Markdown.render("https://example.com/a\u{E001}b\n")
        #expect(html.components(separatedBy: "https://example.com/a\u{E001}b").count == 3, "got \(html)")
    }

    @Test func vaultNamesAndFragmentsAreLookedUpAsTyped() throws {
        let t = try makeTree(["n/doc.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let n = t.appendingPathComponent("n")
        try "intro\n\n## Part\u{E002}\nsection text\n\n## Other\nelse\n".write(to: n.appendingPathComponent("Child.md"), atomically: true, encoding: .utf8)
        try "x".write(to: n.appendingPathComponent("Odd\u{E002}.md"), atomically: true, encoding: .utf8)
        let vault = WikiVault(documentFolder: n)
        let embed = ob("![[Child#Part\u{E002}]]\n", vault: vault)
        #expect(embed.contains("section text") && !embed.contains("else"), "got \(embed)")
        let link = ob("[[Odd\u{E002}|read]]\n", vault: vault)
        #expect(link.contains("href=") && link.contains(">read<"), "got \(link)")
    }

    @Test func theParentsDollarPassLeavesAnEmbeddedNotesMarksAlone() throws {
        let t = try makeTree(["n/doc.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let n = t.appendingPathComponent("n")
        try "child \\\u{E003} end".write(to: n.appendingPathComponent("Child.md"), atomically: true, encoding: .utf8)
        let vault = WikiVault(documentFolder: n)
        var options = Markdown.Options.preview(vault: vault)
        options.math = true
        let html = Markdown.render("\\$1 and $y$\n\n![[Child]]\n", options: options)
        #expect(html.contains("child \\\u{E003} end"), "got \(html)")
        #expect(html.contains("$1") && html.contains("math-inline"), "got \(html)")
    }

    // A heading's anchor is made from the text as typed.
    @Test func aHeadingWithTheCharactersKeepsItsAnchor() {
        #expect(Markdown.render("# a\u{E000}b\n") == Markdown.render("# ab\n").replacingOccurrences(of: ">ab<", with: ">a\u{E000}b<"))
    }

    /// `text` with U+E000…U+E003 as U+E100…U+E103 (`inert`), or back.
    static func swap(_ text: String, inert: Bool) -> String {
        var out = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            let (from, to): (UInt32, UInt32) = inert ? (0xE000, 0xE100) : (0xE100, 0xE000)
            out.append(u.value &- from < 4 ? Unicode.Scalar(u.value - from + to)! : u)
        }
        return String(out)
    }

    /// Whatever a context does with a character (an indent quirk may even
    /// drop it), it does the same with U+E000…U+E003 as with any other
    /// private-use character the render does not use itself.
    static func rendersLikeAnInertCharacter(_ text: String, _ render: (String) -> String) -> (Bool, String, String) {
        let literal = render(text)
        let inert = swap(render(swap(text, inert: true)), inert: false)
        return (literal == inert, literal, inert)
    }

    @Test func everyContextTreatsTheCharactersAsAnyOther() throws {
        let t = try makeTree(["n/doc.md", "n/Note.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let n = t.appendingPathComponent("n")
        let vault = WikiVault(documentFolder: n)
        // ¤ is where the character goes.
        let contexts = [
            "  ```\n\t\u{0600}¤x\n  ```\n", "  ```\n\t¤x\n  ```\n", "```\n¤0¤ `a`\n```\n",
            "    a\n\t¤b\n", "    ¤0¤\n", "- a\n\t¤b\n", "- a\n  ¤b `c`\n", "1. ¤\n\t¤\n",
            "> q¤ `c` **b**\n", "# h¤ `c`\n", "| a | b¤ |\n|---|---|\n| c¤ `d` | ¤0¤ |\n",
            "[a¤b `c`](http://x.y/¤) and ¤0¤\n", "![a¤b `c`](i¤.png)\n", "a[^¤]\n\n[^¤]: x¤ `y`\n",
            "[[Note]] [[Note|al¤ias]] [[No¤te]]\n", "`x` ![[Note]] **b** a  \nz \\$1 $y$\n",
            "a  \n¤ b\\\nc ¤\\$2 $x$ ¤\n", "\\*¤-1¤ ¤0¤ ==h¤== ~~s¤~~ http://a.b/¤c\n",
        ]
        for mark in ["\u{E000}", "\u{E001}", "\u{E002}", "\u{E003}", "\u{E000}0\u{E001}", "\u{E003}\u{E002}\u{E001}\u{E000}"] {
            for context in contexts {
                let text = context.replacingOccurrences(of: "¤", with: mark)
                for obsidian in [false, true] {
                    var options = obsidian ? Markdown.Options.preview(vault: vault) : Markdown.Options()
                    options.math = obsidian
                    let (same, literal, inert) = Self.rendersLikeAnInertCharacter(text) { text in
                        // The embedded note has the same characters as the document.
                        let note = "n¤te `k` ¤0¤ a  \nb".replacingOccurrences(of: "¤", with: mark)
                        let inert = text.unicodeScalars.contains { $0.value &- 0xE100 < 4 }
                        try? (inert ? Self.swap(note, inert: true) : note).write(to: n.appendingPathComponent("Note.md"), atomically: true, encoding: .utf8)
                        return Markdown.render(text, options: options)
                    }
                    #expect(same, "\(text.debugDescription): \(literal.debugDescription) vs \(inert.debugDescription)")
                }
            }
        }
    }

    @Test func aMaxLengthReferenceLabelWithAMarkResolves() {
        let r = String(repeating: "a", count: 998) + "\u{0600}\u{E001}"
        let html = Markdown.render("[label][\(r)]\n\n[\(r)]: /page\n")
        #expect(html.contains("<a href=\"/page\">label</a>"), "got \(html.prefix(200))")
    }

    @Test func highlightDelimitersAroundOneMarkBehaveAsAroundAnyCharacter() {
        let o = Markdown.Options(obsidian: true)
        let plain = Markdown.render("==x==\n", options: o)
        let odd = Markdown.render("==\u{E004}==\n", options: o)
        #expect(plain.contains("<mark>x</mark>"), "got \(plain)")
        #expect(odd == plain.replacingOccurrences(of: "x", with: "\u{E004}"), "got \(odd)")
    }

    // A document that already uses every character of the first private-use
    // block still renders its code spans, links and emphasis.
    @Test func aDocumentFullOfPrivateUseCharactersRendersNormally() {
        var all = ""
        for v in 0xE000...0xE1FF { all.unicodeScalars.append(Unicode.Scalar(v)!) }
        let src = "\(all)\n\n`code` [a](http://b.c/d) **x** \\* \(all)\n\n- item `y`\n\n| h |\n| - |\n| `z` |\n"
        let html = Markdown.render(src)
        #expect(html.contains("<code>code</code>") && html.contains("<a href=\"http://b.c/d\">a</a>") && html.contains("<strong>x</strong>"), "got \(html.prefix(400))")
        #expect(html.contains("<code>y</code>") && html.contains("<code>z</code>"), "got \(html.suffix(300))")
        #expect(html.contains(all), "every character comes out as typed")
    }

    // A folder name with the characters is in the page's links, not in the text.
    @Test func aFolderNameWithTheCharactersDoesNotConfuseALink() throws {
        let t = try makeTree(["n/doc.md", "n/d\u{E000}0\u{E001}ir/Target.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let vault = WikiVault(documentFolder: t.appendingPathComponent("n"))
        let html = ob("`x` [[Target]] `y`\n", vault: vault)
        #expect(html.contains(">Target</a>") && html.contains("<code>x</code>") && html.contains("<code>y</code>"), "got \(html)")
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
            // The same render as with other private-use characters there
            // (none of U+E100… is a piece).
            let inert = Self.swap(Markdown.render(Self.swap(s, inert: true), options: options), inert: false)
            #expect(html == inert, "\(s.debugDescription): \(html.debugDescription) vs \(inert.debugDescription)")
        }
    }
}
