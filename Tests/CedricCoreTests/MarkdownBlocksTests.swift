import Foundation
import Testing
@testable import CedricCore

/// Format › Markdown's line commands (and the Context Bar's buttons):
/// MarkdownBlocks, plus the bar's per-language item sets.
@Suite struct MarkdownBlocksTests {
    func run(_ s: String, _ f: (NSString, NSRange) -> TextEdit?) -> String? {
        let (x, sel) = caretText(s)
        return shown(x, f(x, sel))
    }
    func h(_ level: Int, _ s: String) -> String? { run(s) { MarkdownBlocks.heading(level, in: $0, selection: $1) } }
    func bullet(_ s: String) -> String? { run(s) { MarkdownBlocks.list(.bullet, in: $0, selection: $1) } }
    func numbered(_ s: String) -> String? { run(s) { MarkdownBlocks.list(.numbered, in: $0, selection: $1) } }
    func quote(_ s: String) -> String? { run(s) { MarkdownBlocks.quote(in: $0, selection: $1) } }
    func code(_ s: String) -> String? { run(s) { MarkdownBlocks.codeBlock(in: $0, selection: $1) } }
    func table(_ s: String) -> String? { run(s) { MarkdownBlocks.insertTable(in: $0, selection: $1) } }
    func image(_ s: String, _ clip: String? = nil) -> String? { run(s) { MarkdownBlocks.image(in: $0, selection: $1, clipboard: clip) } }
    func task(_ s: String) -> String? { run(s) { MarkdownLists.toggleTasks(in: $0, selection: $1) } }
    func emph(_ style: MarkdownFormat.Style, _ s: String) -> String? { run(s) { MarkdownFormat.toggle(style, in: $0, selection: $1) } }

    // MARK: Headings

    @Test func headingSetsReplacesAndToggles() {
        #expect(h(2, "Ti‸tle\nnext") == "## Ti‸tle\nnext")
        #expect(h(2, "## Ti‸tle") == "Ti‸tle")
        #expect(h(1, "### Ti‸tle") == "# Ti‸tle")
        #expect(h(3, "‸") == "### ‸")
        #expect(h(0, "## Ti‸tle") == "Ti‸tle")
        #expect(h(0, "plain‸") == nil)
        // The caret in the old marker lands after the new one.
        #expect(h(1, "#‸## x") == "# ‸x")
        // "#tag" isn't a heading: it gets one.
        #expect(h(1, "#t‸ag") == "# #t‸ag")
    }

    @Test func headingOverSeveralLines() {
        #expect(h(2, "‸a\n\nb‸") == "‸## a\n\n## b‸")
        #expect(h(2, "‸## a\n\n## b‸") == "‸a\n\nb‸")
        // Mixed: all become the level.
        #expect(h(2, "‸## a\n# b‸") == "‸## a\n## b‸")
    }

    // MARK: Lists

    @Test func bulletOnAndOff() {
        #expect(bullet("ite‸m") == "- ite‸m")
        #expect(bullet("- ite‸m") == "ite‸m")
        #expect(bullet("‸") == "- ‸")
        #expect(bullet("  ind‸ented") == "  - ind‸ented")
        #expect(bullet("> quo‸ted") == "> - quo‸ted")
        #expect(bullet("- [ ] ta‸sk") == "ta‸sk")
    }

    @Test func multiLineLists() {
        #expect(bullet("‸a\nb\n\nc‸") == "‸- a\n- b\n\n- c‸")
        #expect(bullet("‸- a\n- b\n\n- c‸") == "‸a\nb\n\nc‸")
        #expect(numbered("‸a\nb\nc‸") == "‸1. a\n2. b\n3. c‸")
        #expect(numbered("‸1. a\n2. b‸") == "‸a\nb‸")
        // A selection ending at the start of a line leaves that line out.
        #expect(numbered("‸a\nb\n‸c") == "‸1. a\n2. b‸\nc")
        // Nested: each indent counts on its own.
        #expect(numbered("‸a\n   b\n   c\nd‸") == "‸1. a\n   1. b\n   2. c\n2. d‸")
    }

    @Test func mixedListMarkers() {
        // Bullets keep their own marker; the others take the first one found.
        #expect(bullet("‸* a\n1. b\nc‸") == "‸* a\n* b\n* c‸")
        #expect(bullet("‸+ a\n- b‸") == "‸a\nb‸")
        // Bullets to numbers, checkboxes kept.
        #expect(numbered("‸- a\n* [x] b\n+ c‸") == "‸1. a\n2. [x] b\n3. c‸")
        #expect(numbered("‸1) a\nb‸") == "‸1) a\n2) b‸")
        // Numbers to bullets.
        #expect(bullet("‸1. a\n2. b‸") == "‸- a\n- b‸")
    }

    @Test func listContinuesTheOneAbove() {
        #expect(numbered("1. a\n2. b\nc‸") == "1. a\n2. b\n3. c‸")
        #expect(bullet("* a\nb‸") == "* a\n* b‸")
        // A stale number is put right.
        #expect(numbered("‸5. a\nb‸") == "‸1. a\n2. b‸")
    }

    @Test func checkboxesOverLines() {
        #expect(task("‸a\nb\nc‸") == "‸- [ ] a\n- [ ] b\n- [ ] c‸")
        #expect(task("‸- [ ] a\n- [x] b‸") == "‸- [x] a\n- [ ] b‸")
        #expect(task("1. it‸em") == "1. [ ] it‸em")
    }

    // MARK: Quotes

    @Test func quoteOnAndOff() {
        #expect(quote("sa‸id") == "> sa‸id")
        #expect(quote("> sa‸id") == "sa‸id")
        #expect(quote("‸a\n\nb‸") == "‸> a\n>\n> b‸")
        #expect(quote("‸> a\n>\n> b‸") == "‸a\n\nb‸")
        #expect(quote("‸") == "> ‸")
        // Nested: one level comes off.
        #expect(quote("> > dee‸p") == "> dee‸p")
    }

    // MARK: Code blocks

    @Test func codeBlockWrapsAndUnwraps() {
        #expect(code("le‸t x") == "```\nle‸t x\n```")
        #expect(code("‸") == "```\n‸\n```")
        #expect(code("‸a\nb‸\nafter") == "```\n‸a\nb‸\n```\nafter")
        // Inside a block: its fences go.
        #expect(code("```swift\nle‸t x\n```\nafter") == "le‸t x\nafter")
        #expect(code("```\nlast‸\n```") == "last‸")
        // The whole block selected, fences included.
        #expect(code("‸```\nx\n```‸") == "‸x‸")
        // On the opening fence line.
        #expect(code("```‸\nx\n```\n") == "‸x\n")
        // An unclosed block: the opening line goes.
        #expect(code("```\nx‸\ny") == "x‸\ny")
        // A fence earlier in the text that is closed doesn't count.
        #expect(code("```\na\n```\nb‸") == "```\na\n```\n```\nb‸\n```")
        #expect(code("~~~\nt‸\n~~~") == "t‸")
    }

    // MARK: Tables

    @Test func tableSkeleton() {
        let row = "|     |     |     |", sep = "| --- | --- | --- |"
        #expect(table("‸") == "|‸     |     |     |\n\(sep)\n\(row)\n\(row)".replacingOccurrences(of: "|‸     |", with: "| ‸    |"))
        #expect(table("Prices‸") == "Prices\n\n| ‸    |     |     |\n\(sep)\n\(row)\n\(row)")
        #expect(table("Prices‸\nnext") == "Prices\n\n| ‸    |     |     |\n\(sep)\n\(row)\n\(row)\n\nnext")
        #expect(table("para\n‸\n") == "para\n\n| ‸    |     |     |\n\(sep)\n\(row)\n\(row)\n")
    }

    // MARK: Images

    @Test func imageLinks() {
        #expect(image("a ‸cat‸") == "a ![cat](‸)")
        #expect(image("a ‸cat‸", "https://x.org/c.png") == "a ![cat](https://x.org/c.png)‸")
        #expect(image("‸https://x.org/c.png‸") == "![‸](https://x.org/c.png)")
        #expect(image("go ‸") == "go ![‸]()")
        #expect(image("see ![c‸at](c.png) now") == "see ‸cat‸ now")
        // A link is not an image.
        #expect(image("[l‸ink](u)") == "[l![‸]()ink](u)")
    }

    // MARK: CRLF

    @Test func crlfLinesKeepTheirEndings() {
        #expect(h(1, "‸a\r\nb‸\r\n") == "‸# a\r\n# b‸\r\n")
        #expect(bullet("‸a\r\nb\r\n‸c") == "‸- a\r\n- b‸\r\nc")
        #expect(numbered("x\r\n‸a\r\nb‸") == "x\r\n‸1. a\r\n2. b‸")
        #expect(quote("‸a\r\n\r\nb‸") == "‸> a\r\n>\r\n> b‸")
        #expect(code("a\r\nb‸") == "a\r\n```\r\nb‸\r\n```")
        #expect(code("```\r\nx‸\r\n```\r\nz") == "x‸\r\nz")
        #expect(table("t‸\r\n") == "t\r\n\r\n| ‸    |     |     |\r\n| --- | --- | --- |\r\n|     |     |     |\r\n|     |     |     |\r\n")
        #expect(task("‸a\r\nb‸") == "‸- [ ] a\r\n- [ ] b‸")
        // A selection ending just after "\r\n" leaves the next line out.
        #expect(h(2, "‸a\r\n‸b") == "‸## a\r\n‸b")
        #expect(bullet("‸one‸") == "‸- one‸")
    }

    // MARK: Emphasis

    @Test func nestedEmphasis() {
        // Bold over a span holding bold: merged, not nested.
        #expect(emph(.bold, "‸a **b** c‸") == "**‸a b c‸**")
        #expect(emph(.italic, "‸a *b* c‸") == "*‸a b c‸*")
        // Bold inside italic: added, and taken off again.
        #expect(emph(.bold, "*a ‸b‸ c*") == "*a **‸b‸** c*")
        #expect(emph(.bold, "*a **‸b‸** c*") == "*a ‸b‸ c*")
        // Italic over bold text keeps the bold.
        #expect(emph(.italic, "‸**b** c‸") == "*‸**b** c‸*")
        // An odd marker inside is left alone (not a pair).
        #expect(emph(.bold, "‸2 ** 3‸") == "**‸2 ** 3‸**")
        #expect(emph(.strikethrough, "‸a ~~b~~‸") == "~~‸a b‸~~")
    }

    @Test func emptySelections() {
        #expect(emph(.bold, "‸") == "**‸**")
        #expect(h(1, "‸") == "# ‸")
        #expect(numbered("‸") == "1. ‸")
        #expect(quote("‸") == "> ‸")
        #expect(image("‸") == "![‸]()")
        // A caret past the end of a stale selection never traps.
        let t = "abc" as NSString
        #expect(MarkdownBlocks.heading(1, in: t, selection: NSRange(location: 99, length: 5)) != nil)
        #expect(MarkdownBlocks.list(.bullet, in: "" as NSString, selection: NSRange(location: 0, length: 0))?.replacement == "- ")
    }

    // MARK: The bar's sets

    @Test func contextBarSets() {
        let all = ContextBarSet.items(for: .markdown)
        let md = all
        #expect(md.map(\.id) == ["heading", "bold", "italic", "strikethrough", "code", "link", "bulletList", "numberedList", "checkbox",
                                 "quote", "codeBlock", "table", "image", "preview", "explain", "rewrite"])
        #expect(md.first?.choices.map(\.command) == ["markdownBodyMenu:", "markdownHeading1Menu:", "markdownHeading2Menu:", "markdownHeading3Menu:"])
        #expect(md.filter(\.trailing).map(\.id) == ["preview", "explain", "rewrite"])
        // The Image button picks files (Insert Image…), not the Image Link text command.
        #expect(md.first { $0.id == "image" }?.command == "markdownInsertImageFileMenu:")
        #expect(md.prefix { $0.id != "preview" }.allSatisfy { !$0.trailing })
        #expect(Set(md.map(\.symbol)).count == md.count, "every item has its own symbol")
        // No bar for code or plain text.
        for l in [Language.plain, .swift, .python, .json, .html, .csv] { #expect(ContextBarSet.items(for: l).isEmpty) }
        // Only Markdown has a set (CSV / TSV's Preview eye is on the status bar).
        #expect(Language.allCases.filter(ContextBarSet.hasBar) == [.markdown])
        #expect(ContextBarSet.hasBar(.markdown) && !ContextBarSet.hasBar(.swift))
        #expect(all.suffix(2).map(\.id) == ["explain", "rewrite"])
        #expect(all.suffix(2).map(\.command) == ["explainSelectionMenu:", "rewriteSelectionMenu:"])
        #expect(all.suffix(2).allSatisfy { $0.trailing && !$0.toggle })
        #expect(Set(all.map(\.symbol)).count == all.count)
    }

    /// CSV / TSV: no Context Bar (its Preview eye is on the status bar,
    /// beside the format picker, Bars.swift); Markdown's bar keeps its
    /// eye. .tsv, .tab and .psv are CSV / TSV too, with a preview.
    @Test func contextBarCSVPreviewToggle() {
        #expect(ContextBarSet.items(for: .csv).isEmpty)
        #expect(!ContextBarSet.hasBar(.csv))
        let mdPreview = ContextBarSet.items(for: .markdown).first { $0.id == "preview" }
        #expect(mdPreview?.command == "togglePreview:" && mdPreview?.symbol == "eye" && mdPreview?.toggle == true && mdPreview?.trailing == true)
        #expect(Language.csv.hasPreview)
        for name in ["people.csv", "cols.tsv", "data.tab", "pipes.psv"] {
            let l = LanguageDetector.detect(fileName: name, content: "a,b\n1,2\n")
            #expect(l == .csv, "\(name)")
            #expect(l.hasPreview && !ContextBarSet.hasBar(l), "\(name)")
        }
    }

    /// UX review #21: Strikethrough on the bar (Format › Markdown's ⇧⌘X
    /// command), and a preview symbol that doesn't read as a sidebar.
    @Test func contextBarStrikethroughAndPreviewSymbol() {
        let md = ContextBarSet.items(for: .markdown)
        let strike = md.first { $0.id == "strikethrough" }
        #expect(strike?.command == "markdownStrikethroughMenu:" && strike?.symbol == "strikethrough")
        let preview = md.first { $0.id == "preview" }
        #expect(preview?.symbol == "eye" && preview?.toggle == true)
        #expect(!md.contains { $0.symbol.hasPrefix("sidebar") })
    }
}
