import Foundation
import Testing
@testable import CedricCore

/// Ask Cedric's pure parts: the frozen snapshot, the context chip and
/// proposals going stale.
@Suite struct OwlChatContextTests {
    static let doc = "one\ntwo\nthree\nfour\nfive"

    @Test func snapshotLinesAreOneBasedAndClamped() {
        let s = OwlDocumentSnapshot(text: Self.doc, generation: 1)
        #expect(s.lineCount == 5)
        #expect(s.range(lines: 2, 3) == NSRange(location: 4, length: 9))
        #expect(s.substring(s.range(lines: 4, 99)!) == "four\nfive")
        #expect(s.range(lines: 6, 7) == nil)
        #expect(s.numbered(lines: 2, 3) == "2| two\n3| three")
        #expect(s.lineNumber(at: 0) == 1 && s.lineNumber(at: 4) == 2)
    }

    @Test func selectionEndingAfterANewlineDoesNotTakeTheNextLine() {
        let s = OwlDocumentSnapshot(text: Self.doc, generation: 1, selection: NSRange(location: 4, length: 4))  // "two\n"
        let span = s.lineSpan(s.selection)
        #expect(span.first == 2 && span.last == 2)
    }

    @Test func scopesOfferSelectionOnlyWithOneAndAlwaysOfferWhole() {
        let s = OwlDocumentSnapshot(text: Self.doc, generation: 1)
        #expect(OwlChatContext.scopes(for: s, budget: 1000) == [.visible, .wholeDocument])
        #expect(OwlChatContext.scopes(for: s, budget: 10) == [.visible, .wholeDocument])
        let sel = OwlDocumentSnapshot(text: Self.doc, generation: 1, selection: NSRange(location: 4, length: 3))
        #expect(OwlChatContext.scopes(for: sel, budget: 1000) == [.selection, .visible, .wholeDocument])
        #expect(OwlChatContext.defaultScope(for: sel, budget: 1000) == .selection)
        #expect(OwlChatContext.build(s, scope: .selection, budget: 1000) == nil)
    }

    @Test func wholeDocumentWindowCentresOnCaretOrSelection() throws {
        let text = (1...100).map { "marker-\($0) " + String(repeating: "x", count: 22) }.joined(separator: "\n") + "\n"
        let ns = text as NSString
        for line in [2, 50, 99] {
            let caret = ns.range(of: "marker-\(line) ").location
            let s = OwlDocumentSnapshot(text: text, generation: 1, selection: NSRange(location: caret, length: 0))
            let ctx = try #require(OwlChatContext.build(s, scope: .wholeDocument, budget: 400))
            #expect(ctx.truncated && ctx.numbered.contains("marker-\(line) "))
            #expect((ctx.numbered as NSString).length <= 400)
            if line == 2 { #expect(ctx.firstLine == 1) }
            if line == 99 { #expect(ctx.lastLine == 100) }
            if line == 50 { #expect(ctx.firstLine < line && ctx.lastLine > line) }
        }
        let start = ns.range(of: "marker-30 ").location
        let end = ns.range(of: "marker-70 ").location
        let s = OwlDocumentSnapshot(text: text, generation: 1, selection: NSRange(location: start, length: end - start))
        let midpointLine = s.lineNumber(at: start + (end - start) / 2)
        let ctx = try #require(OwlChatContext.build(s, scope: .wholeDocument, budget: 100))
        #expect(ctx.firstLine <= midpointLine && ctx.lastLine >= midpointLine)
        let oversized = OwlDocumentSnapshot(text: "😀😀😀\nx", generation: 1)
        let one = try #require(OwlChatContext.build(oversized, scope: .wholeDocument, budget: 2))
        #expect(one.numbered == "1| 😀😀😀" && one.truncated)
    }

    @Test func largeScriptDefaultsToWholeAndVisibleRemainsAChoice() throws {
        let text = (1...263).map { i in
            let prefix = "line-\(i) "
            return prefix + String(repeating: "x", count: (i <= 52 ? 36 : 35) - prefix.count)
        }.joined(separator: "\n")
        #expect((text as NSString).length == 9_519)
        let ns = text as NSString
        let caret = ns.range(of: "line-132 ").location
        let visibleEnd = ns.range(of: "line-53 ").location
        let s = OwlDocumentSnapshot(text: text, generation: 1, selection: NSRange(location: caret, length: 0),
                                    visible: NSRange(location: 0, length: visibleEnd), language: "python")
        #expect(OwlChatContext.defaultScope(for: s, budget: 5_000) == .wholeDocument)
        #expect(OwlChatContext.scopes(for: s, budget: 5_000).contains(.visible))
        let ctx = try #require(OwlChatContext.build(s, scope: .wholeDocument, budget: 5_000))
        #expect(ctx.truncated && ctx.numbered.contains("line-132 "))
        #expect(ctx.lastLine - ctx.firstLine + 1 > 52)
        #expect(ctx.label == "Lines \(ctx.firstLine)–\(ctx.lastLine) of 263 (trimmed to fit)")
        let visible = try #require(OwlChatContext.build(s, scope: .visible, budget: 5_000))
        #expect(visible.firstLine == 1 && visible.lastLine == 52 && !visible.truncated)
        #expect(visible.label == "Visible text (52 lines)")
    }

    @Test func wholeDocumentThatFitsIncludesOnlyCountedLines() throws {
        let s = OwlDocumentSnapshot(text: "one\ntwo\n", generation: 1)
        let ctx = try #require(OwlChatContext.build(s, scope: .wholeDocument, budget: 13))
        #expect(OwlChatContext.defaultScope(for: s, budget: 13) == .wholeDocument)
        #expect(!ctx.truncated && ctx.numbered == "1| one\n2| two")
        #expect(ctx.label == "Whole document (2 lines)")
    }

    @Test func contextIsNumberedWholeLinesTrimmedToTheBudget() {
        let s = OwlDocumentSnapshot(text: Self.doc, generation: 1, selection: NSRange(location: 5, length: 6), visible: NSRange(location: 0, length: 23))
        let sel = OwlChatContext.build(s, scope: .selection, budget: 1000)!
        #expect(sel.numbered == "2| two\n3| three")
        #expect(sel.label == "Selection (2 lines)")
        let vis = OwlChatContext.build(s, scope: .visible, budget: 20)!
        #expect(vis.firstLine == 1 && vis.truncated)
        #expect(vis.numbered.hasPrefix("1| one"))
        #expect(!vis.numbered.contains("five"))
    }

    @Test func proposalAppliesOnlyToTheUnchangedDocument() {
        let s = OwlDocumentSnapshot(text: Self.doc, generation: 4)
        let p = OwlEditProposal.lines(2, 3, with: "TWO\nTHREE\n", in: s)!
        #expect(p.original == "two\nthree" && p.replacement == "TWO\nTHREE")   // trailing newline dropped
        #expect(p.isCurrent(text: Self.doc as NSString, generation: 4))
        #expect(!p.isCurrent(text: Self.doc as NSString, generation: 5))                              // edited (and maybe undone)
        #expect(!p.isCurrent(text: "one\ntwo!\nthree\nfour\nfive" as NSString, generation: 4))       // text moved under it
        #expect(!p.isCurrent(text: "one" as NSString, generation: 4))                                 // shorter
        #expect(OwlEditProposal.lines(2, 2, with: "two", in: s) == nil)                               // no change
        #expect(OwlEditProposal.lines(9, 9, with: "x", in: s) == nil)
    }

    @Test func proposalDiffAndMarkdown() {
        let s = OwlDocumentSnapshot(text: Self.doc, generation: 1)
        let p = OwlEditProposal.lines(2, 3, with: "two\nTHREE", in: s)!
        #expect(p.unifiedText == "  two\n- three\n+ THREE")
        let md = OwlChatEntry.markdown([OwlChatEntry(role: .user, text: "Fix"), OwlChatEntry(role: .owl, text: "Done", proposal: p)], fileName: "a.txt")
        #expect(md.hasPrefix("# Ask Cedric — a.txt\n"))
        #expect(md.contains("**You:** Fix") && md.contains("```diff\n  two\n- three\n+ THREE\n```"))
    }
}
