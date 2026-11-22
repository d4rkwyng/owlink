import Foundation
import Testing
@testable import CedricCore

@Suite struct AutoEditTests {
    func nl(_ s: String, _ lang: Language = .swift) -> (String, Int) {
        // "|" marks the caret.
        let caret = (s as NSString).range(of: "|").location
        let t = (s.replacingOccurrences(of: "|", with: "")) as NSString
        let start = t.lineRange(for: NSRange(location: caret, length: 0)).location
        let r = AutoEdit.newline(in: t, lineStart: start, caret: caret, after: caret, language: lang)
        return (r.text, r.caret)
    }

    @Test func returnKeepsAndAddsIndent() {
        #expect(nl("    let a = 1|") == ("\n    ", 5))
        #expect(nl("\tx|") == ("\n\t", 2))
        // After an opener: one step more; between a pair: the closer on its own line.
        #expect(nl("if x {|") == ("\n    ", 5))
        #expect(nl("  f(|)") == ("\n      \n  ", 7))
        #expect(nl("\tlet a = [|]") == ("\n\t\t\n\t", 3))
        // Python and YAML colons; YAML steps by 2.
        #expect(nl("def f():|", .python) == ("\n    ", 5))
        #expect(nl("key:|", .yaml) == ("\n  ", 3))
        #expect(nl("key: 1|", .yaml) == ("\n", 1))
        // Plain text and Markdown keep the indent only.
        #expect(nl("  note {|", .plain) == ("\n  ", 3))
        #expect(nl("- item:|", .markdown) == ("\n", 1))
        // Trailing spaces after the opener don't hide it.
        #expect(nl("x {  |") == ("\n    ", 5))
        // A blank indented line keeps its indent.
        #expect(nl("    |") == ("\n    ", 5))
    }

    @Test func pairingSkipAndWrap() {
        func t(_ c: Character, _ before: Character?, _ after: Character?, sel: Bool = false, _ lang: Language = .swift) -> AutoEdit.Typing? {
            AutoEdit.typing(c.utf16.first!, before: before?.utf16.first, after: after?.utf16.first, hasSelection: sel, language: lang)
        }
        #expect(t("(", "f", nil) == .pair("()"))
        #expect(t("{", " ", "\n") == .pair("{}"))
        #expect(t("[", nil, ")") == .pair("[]"))
        // Not in front of a word.
        #expect(t("(", " ", "x") == nil)
        // Skip over an existing closer or quote.
        #expect(t(")", "x", ")") == .skip)
        #expect(t("\"", "x", "\"") == .skip)
        #expect(t(")", "x", nil) == nil)
        // Quotes: not after a word character (don't), pair otherwise.
        #expect(t("'", "n", nil) == nil)
        #expect(t("\"", " ", nil) == .pair("\"\""))
        #expect(t("`", " ", nil, .javascript) == .pair("``"))
        #expect(t("`", " ", nil, .swift) == nil)
        // A quote steps over only a closer pairing put there, not one that
        // was already in the text (the start of the next string).
        #expect(AutoEdit.typing(34, before: 32, after: 34, hasSelection: false, language: .swift, afterIsAutoClosed: false) == nil)
        #expect(AutoEdit.typing(41, before: 32, after: 41, hasSelection: false, language: .swift, afterIsAutoClosed: false) == .skip)
        // No ' pairing where it never quotes a string: Swift, JSON. Still in C, Python, JS, Ruby, SQL.
        #expect(t("'", " ", nil, .swift) == nil)
        #expect(t("'", " ", nil, .json) == nil)
        #expect(!AutoEdit.deletesPair(before: 39, after: 39, language: .swift))
        for lang in [Language.c, .python, .javascript, .ruby, .sql, .shell] { #expect(t("'", " ", nil, lang) == .pair("''"), "\(lang)") }
        // A selection is wrapped.
        #expect(t("(", "a", "b", sel: true) == .wrap("(", ")"))
        #expect(t("\"", "a", "b", sel: true) == .wrap("\"", "\""))
        // Never in prose.
        #expect(t("(", nil, nil, .plain) == nil)
        #expect(t("\"", " ", nil, .markdown) == nil)
        #expect(t("(", nil, nil, .diff) == nil)
        #expect(!AutoEdit.pairs(in: .diff))
    }

    @Test func pairedDelete() {
        func d(_ b: Character, _ a: Character, _ lang: Language = .swift) -> Bool {
            AutoEdit.deletesPair(before: b.utf16.first, after: a.utf16.first, language: lang)
        }
        #expect(d("(", ")"))
        #expect(d("{", "}"))
        #expect(d("\"", "\""))
        #expect(!d("(", "]"))
        #expect(!d("a", "a"))
        #expect(!d("(", ")", .plain))
    }

    @Test func matchingBrackets() {
        let t = "f(a[1], {b: (c)})" as NSString
        // Caret just after "(" at 1: its partner is the last ")".
        #expect(AutoEdit.matchingBracket(in: t, caret: 2)! == (NSRange(location: 1, length: 1), NSRange(location: 16, length: 1)))
        // Caret before "{": forward to its "}".
        #expect(AutoEdit.matchingBracket(in: t, caret: 8)! == (NSRange(location: 8, length: 1), NSRange(location: 15, length: 1)))
        // After a closer: back to its opener.
        #expect(AutoEdit.matchingBracket(in: t, caret: 6)! == (NSRange(location: 5, length: 1), NSRange(location: 3, length: 1)))
        #expect(AutoEdit.matchingBracket(in: "abc" as NSString, caret: 1) == nil)
        // Unbalanced, or the partner past the limit: nil.
        #expect(AutoEdit.matchingBracket(in: "((x)" as NSString, caret: 1) == nil)
        let far = ("(" + String(repeating: "x", count: 50) + ")") as NSString
        #expect(AutoEdit.matchingBracket(in: far, caret: 1, limit: 10) == nil)
        #expect(AutoEdit.matchingBracket(in: far, caret: 1, limit: 100) != nil)
    }

    @Test func matchingUsesUTF16OffsetsAroundUnicode() {
        let text = "😀[a(b)c]" as NSString
        #expect(AutoEdit.matchingBracket(in: text, caret: 3)! == (NSRange(location: 2, length: 1), NSRange(location: 8, length: 1)))
        #expect(AutoEdit.matchingBracket(in: text, caret: 5)! == (NSRange(location: 4, length: 1), NSRange(location: 6, length: 1)))
    }

    // Per-caret edits (multiple carets): the same decisions as `typing`, as edits.

    @Test func typingEditPairsSkipsAndWraps() {
        let t = "f() x" as NSString
        // "(" before a space pairs; the caret goes between.
        #expect(AutoEdit.typingEdit(40, in: t, selection: NSRange(location: 3, length: 0), language: .swift)
            == TextEdit(range: NSRange(location: 3, length: 0), replacement: "()", selection: NSRange(location: 4, length: 0)))
        // ")" before ")" steps over it: nothing replaced, caret after.
        #expect(AutoEdit.typingEdit(41, in: t, selection: NSRange(location: 2, length: 0), language: .swift)
            == TextEdit(range: NSRange(location: 2, length: 0), replacement: "", selection: NSRange(location: 3, length: 0)))
        // A selection is wrapped and stays selected.
        #expect(AutoEdit.typingEdit(91, in: t, selection: NSRange(location: 4, length: 1), language: .swift)
            == TextEdit(range: NSRange(location: 4, length: 1), replacement: "[x]", selection: NSRange(location: 5, length: 1)))
        // A plain insert (a letter; or prose): nil.
        #expect(AutoEdit.typingEdit(97, in: t, selection: NSRange(location: 0, length: 0), language: .swift) == nil)
        #expect(AutoEdit.typingEdit(40, in: t, selection: NSRange(location: 3, length: 0), language: .plain) == nil)
    }

    @Test func newlineEditKeepsIndentPerCaret() {
        let t = "    a {}\n\tb" as NSString
        #expect(AutoEdit.newlineEdit(in: t, lineStart: 0, selection: NSRange(location: 7, length: 0), language: .swift)
            == TextEdit(range: NSRange(location: 7, length: 0), replacement: "\n        \n    ", selection: NSRange(location: 16, length: 0)))
        #expect(AutoEdit.newlineEdit(in: t, lineStart: 9, selection: NSRange(location: 11, length: 0), language: .swift)
            == TextEdit(range: NSRange(location: 11, length: 0), replacement: "\n\t", selection: NSRange(location: 13, length: 0)))
    }
}
