import Foundation
import Testing
@testable import CedricCore

/// The second batch of non-AI rules: each fires on what it's for, stays
/// quiet on the near misses, and its Fix it produces the right text.
@Suite struct OwlMoreRulesTests {
    let rules = RulesHintProvider()

    func check(_ text: String, language: String = "plain", fileName: String? = nil, selection: NSRange? = nil,
               facts: OwlDocumentFacts = OwlDocumentFacts()) -> [OwlHint] {
        let ctx = OwlContext(fileName: fileName, language: language, text: text, textStart: 0,
                             visibleRange: NSRange(location: 0, length: 0), selection: selection, documentID: UUID(), editGeneration: 0)
        return rules.check(ctx, facts: facts)
    }

    func find(_ id: String, _ text: String, language: String = "plain", fileName: String? = nil, selection: NSRange? = nil,
              facts: OwlDocumentFacts = OwlDocumentFacts()) -> OwlHint? {
        check(text, language: language, fileName: fileName, selection: selection, facts: facts).first { $0.id == id }
    }

    func apply(_ h: OwlHint, to text: String) -> String {
        (text as NSString).replacingCharacters(in: h.range!, with: h.replacement!)
    }

    @Test func mergeConflictMarkers() throws {
        let text = "let a = 1\n<<<<<<< HEAD\nlet b = 2\n=======\nlet b = 3\n>>>>>>> feature\n"
        let h = try #require(find(RulesHintProvider.conflictID, text, language: "swift"))
        #expect(h.kind == .warning && h.replacement == nil)
        #expect(h.title == "Merge conflict markers left on line 2.")
        #expect((text as NSString).substring(with: h.range!) == "<<<<<<< HEAD")
        // A window that isn't the whole document doesn't claim a line number.
        #expect(find(RulesHintProvider.conflictID, text, facts: .init(isWholeDocument: false))?.title == "Merge conflict markers left near here.")
        // Not without all three, in order; not a Markdown/ASCII-art rule.
        #expect(find(RulesHintProvider.conflictID, "<<<<<<< HEAD\nx\n>>>>>>> b\n") == nil)
        #expect(find(RulesHintProvider.conflictID, "=======\n<<<<<<< a\n>>>>>>> b\n") == nil)
        #expect(find(RulesHintProvider.conflictID, "Title\n=======\n\ntext\n") == nil)
        #expect(find(RulesHintProvider.conflictID, "a <<<<<<< b\n=======\n>>>>>>> c\n") == nil)
    }

    @Test func secretsWarnWithAPlaceholderFix() throws {
        // Obviously fake, and built in pieces so no scanner mistakes this file for a leak.
        let aws = "AK" + "IA" + String(repeating: "FAKE", count: 4)
        let gh = "gh" + "p_" + String(repeating: "x", count: 36)
        let key = String(repeating: "-", count: 5) + "BEGIN RSA " + "PRIVATE KEY" + String(repeating: "-", count: 5)
        for (s, kind) in [(aws, "an AWS access key"), (gh, "a GitHub token"), (key, "a private key")] {
            let h = try #require(find(RulesHintProvider.secretID, "config:\n  token = \(s)\n"), "\(kind)")
            #expect(h.kind == .warning)
            // 0.3.0: Fix it puts a placeholder in; a private key needs its END line in view for that.
            #expect(h.replacement == (kind == "a private key" ? nil : "<REDACTED>"))
            #expect(h.detail?.contains(kind) == true)
            #expect(h.detail?.contains("line 2") == true)
        }
        // Near misses: too short, lower case, a public key, the word "AKIA".
        for s in ["AK" + "IA" + "FAKE", "ak" + "ia" + String(repeating: "fake", count: 4), "gh" + "p_" + "short",
                  "-----BEGIN PUBLIC KEY-----", "What does AKIA mean?", "sk-1234"] {
            #expect(find(RulesHintProvider.secretID, s) == nil, "\(s)")
        }
    }

    @Test func apiKeysNeedTheirShape() throws {
        // Obviously fake keys, built in pieces: a random-looking mix of upper, lower and digits.
        let body = String(repeating: "FaKe0", count: 8)
        for k in ["s" + "k-" + body, "s" + "k-ant-" + "api03-" + body + "_x-Y", "s" + "k-proj-" + body + "-Ab_9"] {
            let h = try #require(find(RulesHintProvider.secretID, "key = \(k)\n"), "\(k)")
            #expect(h.detail?.contains("OpenAI or Anthropic") == true)
        }
        // Slugs and words after "sk-" aren't keys.
        for s in ["s" + "k-learn-model-selection-cross-validation-guide-v2",
                  "s" + "k-" + String(repeating: "a", count: 40),
                  "s" + "k-ant-" + "this-is-just-a-long-lower-case-hyphenated-slug",
                  "s" + "k-" + String(repeating: "Ab", count: 20)] {
            #expect(find(RulesHintProvider.secretID, "see \(s) for details\n") == nil, "\(s)")
        }
    }

    @Test func invalidJSONSaysWhere() throws {
        let text = "{\n  \"a\": 1,\n  \"b\": [1, 2,]\n}\n"
        let h = try #require(find(RulesHintProvider.jsonInvalidID, text, language: "json"))
        #expect(h.title == "Extra comma before “]” on line 3.")
        #expect((text as NSString).substring(with: h.range!) == ",")
        // Anything else: where the parser stopped.
        let missing = "{\n  \"a\": 1,\n  \"b\": [1 2]\n}\n"
        let m = try #require(find(RulesHintProvider.jsonInvalidID, missing, language: "json"))
        #expect(m.title == "This JSON doesn’t parse (line 3).")
        #expect(m.detail?.contains("line 3") == true)
        #expect((missing as NSString).substring(with: m.range!) == "  \"b\": [1 2]")
        // Valid, empty, not JSON, a window, or a file whose JSON allows comments.
        #expect(find(RulesHintProvider.jsonInvalidID, "{\n  \"a\": [1, 2]\n}\n", language: "json") == nil)
        #expect(find(RulesHintProvider.jsonInvalidID, "  \n", language: "json") == nil)
        #expect(find(RulesHintProvider.jsonInvalidID, text, language: "javascript") == nil)
        #expect(find(RulesHintProvider.jsonInvalidID, text, language: "json", facts: .init(isWholeDocument: false)) == nil)
        #expect(find(RulesHintProvider.jsonInvalidID, text, language: "json", fileName: "tsconfig.json") == nil)
        #expect(find(RulesHintProvider.jsonInvalidID, "{\n  // comment\n  \"a\": 1\n}\n", language: "json") == nil)
    }

    @Test func unbalancedBrackets() throws {
        // A closer that doesn't match its opener: always.
        let swift = "func a() {\n    let x = [1, 2)\n}\n"
        let h = try #require(find(RulesHintProvider.bracketsID, swift, language: "swift"))
        #expect(h.title == "“[” closed by “)” on line 2.")
        #expect(h.range == NSRange(location: (swift as NSString).range(of: ")\n}").location, length: 1))
        #expect(find(RulesHintProvider.bracketsID, "x = 1)\n", language: "python")?.title == "An extra “)” on line 1.")
        // Never closed: only in a saved file, not while typing.
        let open = "function f() {\n  return 1;\n"
        #expect(find(RulesHintProvider.bracketsID, open, language: "javascript")?.title == "“{” on line 1 is never closed.")
        #expect(find(RulesHintProvider.bracketsID, open, language: "javascript", facts: .init(unsavedSince: Date())) == nil)
        // Brackets in strings, comments, regexes and interpolations don't count.
        let fine: [(String, String)] = [
            ("swift", "let s = \"(\" + \"\\(a[0])]\" // )\n/* { /* nested ] */ */\nlet r = #\"\\d+)\"#\nlet m = \"\"\"\n  ((\n  \"\"\"\n"),
            ("javascript", "const re = /[(]+\\)/g;\nconst t = `a ${b(c)} )`;\nconst q = '{';\nconst d = a / (b / c);\n"),
            ("python", "s = 'it''s ('  # ]\nt = \"\"\"\n)\n\"\"\"\nprint(f\"{x}\")\n"),
            ("c", "char c = '(';\n#include <stdio.h>\nint main() { return 0; } /* } */\n"),
            ("css", "a { background: url(\"x).png\"); } /* { */\n"),
        ]
        for (lang, code) in fine { #expect(find(RulesHintProvider.bracketsID, code, language: lang) == nil, "\(lang)") }
        // C with #if/#else branches that each open a brace: not "never closed", nor an extra closer.
        let ifdef = "#ifdef WIN32\nif (a) {\n#else\nif (b) {\n#endif\n    run();\n}\n"
        #expect(find(RulesHintProvider.bracketsID, ifdef, language: "c") == nil)
        let ifdef2 = "void f() {\n#if X\n}\n#else\n}\n#endif\n"
        #expect(find(RulesHintProvider.bracketsID, ifdef2, language: "c") == nil)
        // Without conditionals it still warns.
        #expect(find(RulesHintProvider.bracketsID, "void f() {\n  g();\n", language: "c")?.title == "“{” on line 1 is never closed.")
        // Swift regex literals: bare and extended.
        let regexes = "let a = /[(]+/\nlet b = #/\\d+ ( [a-z\n]* /#\nlet c = x.firstMatch(of: /\\)/)\nlet d = e / (f / g)\n"
        #expect(find(RulesHintProvider.bracketsID, regexes, language: "swift") == nil)
        // Division isn't taken for a regex: a real missing closer after it is still found.
        #expect(find(RulesHintProvider.bracketsID, "let d = (e / f\nlet g = [1, 2)\n", language: "swift") != nil)
        // Not for languages it can't lex well, nor a window.
        #expect(find(RulesHintProvider.bracketsID, "case $x in\n a) echo;;\nesac\n", language: "shell") == nil)
        #expect(find(RulesHintProvider.bracketsID, swift, language: "swift", facts: .init(isWholeDocument: false)) == nil)
    }

    @Test func curlyQuotesInCodeAreStraightened() throws {
        let text = "print(“hello”)\nlet s = \"it’s fine in a string\"\n// and “here” in a comment\nlet c = ‘x’\n"
        let h = try #require(find(RulesHintProvider.smartQuotesID, text, language: "swift"))
        #expect(h.kind == .fix)
        #expect(apply(h, to: text) == "print(\"hello\")\nlet s = \"it’s fine in a string\"\n// and “here” in a comment\nlet c = 'x'\n")
        #expect(find(RulesHintProvider.smartQuotesID, "let s = \"“quoted”\" // ‘ok’\n", language: "swift") == nil)
        #expect(find(RulesHintProvider.smartQuotesID, "He said “hi”.\n", language: "plain") == nil)
        #expect(find(RulesHintProvider.smartQuotesID, "He said “hi”.\n", language: "markdown") == nil)
    }

    @Test func yamlTabsBecomeSpaces() throws {
        let text = "root:\n\tchild: 1\n\t\tdeep: 2\n  ok: 3\n"
        let h = try #require(find(RulesHintProvider.yamlTabsID, text, language: "yaml"))
        #expect(apply(h, to: text) == "root:\n  child: 1\n    deep: 2\n  ok: 3\n")
        // The generic mixed-indent offer stands down for YAML.
        #expect(find(RulesHintProvider.mixedIndentID, text, language: "yaml") == nil)
        #expect(find(RulesHintProvider.yamlTabsID, "root:\n  child: \"a\tb\"\n", language: "yaml") == nil)
        #expect(find(RulesHintProvider.yamlTabsID, text, language: "plain") == nil)
    }

    @Test func invisibleCharactersAreRemoved() throws {
        let code = "let\u{00A0}x = 1\nlet y\u{200B} = 2\n"
        let h = try #require(find(RulesHintProvider.invisibleID, code, language: "swift"))
        #expect(apply(h, to: code) == "let x = 1\nlet y = 2\n")
        #expect(h.detail?.hasPrefix("2 ") == true)
        // Prose: only a stray byte-order mark; non-breaking spaces are meant there.
        let prose = "10\u{00A0}km\u{FEFF} away\n"
        let p = try #require(find(RulesHintProvider.invisibleID, prose))
        #expect(apply(p, to: prose) == "10\u{00A0}km away\n")
        #expect(find(RulesHintProvider.invisibleID, "10\u{00A0}km and a zero\u{200B}width\n") == nil)
        #expect(find(RulesHintProvider.invisibleID, "let x = 1\n", language: "swift") == nil)
    }

    @Test func todoListBecomesCheckboxes() throws {
        let text = "Todo for Saturday\n- milk\n- eggs\n* call Mum\n\nOther notes\n"
        let h = try #require(find(RulesHintProvider.todoListID, text))
        #expect(h.title == "It looks like you’re writing a to-do list. Checkboxes?")
        #expect(apply(h, to: text) == "Todo for Saturday\n- [ ] milk\n- [ ] eggs\n- [ ] call Mum\n\nOther notes\n")
        let boxes = "[ ] one\n[x] two\n[ ] three\n"
        let b = try #require(find(RulesHintProvider.todoListID, boxes))
        #expect(apply(b, to: boxes) == "- [ ] one\n- [x] two\n- [ ] three\n")
        // A plain bullet list without a to-do title, two items, Markdown already, or a Markdown tab.
        #expect(find(RulesHintProvider.todoListID, "Ingredients\n- milk\n- eggs\n- flour\n") == nil)
        #expect(find(RulesHintProvider.todoListID, "Todo\n- milk\n- eggs\n") == nil)
        #expect(find(RulesHintProvider.todoListID, "Todo\n- [ ] milk\n- [ ] eggs\n- [ ] flour\n") == nil)
        #expect(find(RulesHintProvider.todoListID, text, language: "markdown") == nil)
        #expect(find(RulesHintProvider.todoListID, text, facts: .init(isWholeDocument: false)) == nil)
    }

    @Test func plainTextThatIsReallyMarkdown() throws {
        let md = "# Notes\n\nSome **bold** text and a [link](https://example.com).\n\n- one\n- two\n"
        let h = try #require(check(md, fileName: "notes.txt").first { $0.id.hasPrefix(RulesHintProvider.languageGuessPrefix) })
        #expect(RulesHintProvider.guessedLanguage(h) == .markdown)
        #expect(h.title == "This looks like Markdown. Colour it that way?")
        #expect(h.replacement == nil)
        let html = check("<!DOCTYPE html>\n<html><body><p>Hi</p></body></html>\n").first { $0.id.hasPrefix(RulesHintProvider.languageGuessPrefix) }
        #expect(html.flatMap(RulesHintProvider.guessedLanguage) == .html)
        // Chosen by hand, already Markdown, a lone heading, or YAML-ish notes: quiet.
        #expect(check(md, facts: .init(languageIsManual: true)).allSatisfy { !$0.id.hasPrefix(RulesHintProvider.languageGuessPrefix) })
        #expect(check(md, language: "markdown").allSatisfy { !$0.id.hasPrefix(RulesHintProvider.languageGuessPrefix) })
        #expect(check("# Shopping\nmilk\n").allSatisfy { !$0.id.hasPrefix(RulesHintProvider.languageGuessPrefix) })
        #expect(check("Name: Bob\nDate: Monday\nRoom: 4\n").allSatisfy { !$0.id.hasPrefix(RulesHintProvider.languageGuessPrefix) })
    }

    @Test func wordsTypedTwice() throws {
        let text = "I went to the the shop.\nThe the end was\nwas near."
        let h = try #require(find(RulesHintProvider.duplicateWordID, text))
        #expect(h.title == "3 words typed twice. Fix them?")
        #expect(apply(h, to: text) == "I went to the shop.\nThe end was near.")
        let one = try #require(find(RulesHintProvider.duplicateWordID, "Fix the the bug\n"))
        #expect(one.title == "“the the”? A word typed twice. Fix it?")
        // Meant twice, proper names, other words, code, a column of words, Markdown code.
        for s in ["I know that that is true.", "She had had enough.", "Duran Duran played.", "the theory", "bye bye now",
                  "yes\nyes\nno\n"] {
            #expect(find(RulesHintProvider.duplicateWordID, s) == nil, "\(s)")
        }
        #expect(find(RulesHintProvider.duplicateWordID, "int int x;", language: "c") == nil)
        // Tab-separated columns, case-differing pairs, grammatical doubles in other languages.
        for s in ["name\tname\tage\n", "ERROR error in step 2\n", "Error ERROR\n", "Ich glaube, die die Regeln kennen.",
                  "Das das stimmt.", "Nous nous sommes levés.", "Vous vous trompez.", "Der der Mann.", "error  error\n"] {
            #expect(find(RulesHintProvider.duplicateWordID, s) == nil, "\(s)")
        }
        #expect(find(RulesHintProvider.duplicateWordID, "The the end.\n") != nil)
        #expect(find(RulesHintProvider.duplicateWordID, "Run `go go` now\n", language: "markdown") == nil)
        #expect(find(RulesHintProvider.duplicateWordID, "```\nthe the\n```\n", language: "markdown") == nil)
    }

    @Test func twoSpacesAfterSomeFullStops() throws {
        let text = "One here.  Two here. Three here.  Four here. Five."
        let h = try #require(find(RulesHintProvider.doubleSpaceID, text))
        #expect(apply(h, to: text) == "One here. Two here. Three here. Four here. Five.")
        // Consistent either way: the writer's choice.
        #expect(find(RulesHintProvider.doubleSpaceID, "One.  Two.  Three.  Four.") == nil)
        #expect(find(RulesHintProvider.doubleSpaceID, "One. Two. Three. Four.") == nil)
        #expect(find(RulesHintProvider.doubleSpaceID, text, language: "swift") == nil)
    }

    @Test func finalNewlineInSavedCodeFiles() throws {
        let text = "print(1)"
        let h = try #require(find(RulesHintProvider.finalNewlineID, text, language: "python", fileName: "a.py", selection: NSRange(location: 0, length: 0)))
        #expect(h.kind == .tip)
        #expect(apply(h, to: text) == "print(1)\n")
        // Typing at the end, unsaved, untitled, prose, JSON, or already there.
        #expect(find(RulesHintProvider.finalNewlineID, text, language: "python", fileName: "a.py", selection: NSRange(location: 8, length: 0)) == nil)
        #expect(find(RulesHintProvider.finalNewlineID, text, language: "python", fileName: "a.py", facts: .init(unsavedSince: Date())) == nil)
        #expect(find(RulesHintProvider.finalNewlineID, text, language: "python") == nil)
        #expect(find(RulesHintProvider.finalNewlineID, "notes", fileName: "a.txt") == nil)
        #expect(find(RulesHintProvider.finalNewlineID, "{}", language: "json", fileName: "a.json") == nil)
        #expect(find(RulesHintProvider.finalNewlineID, "print(1)\n", language: "python", fileName: "a.py") == nil)
    }

    @Test func mixedLineEndingsReplaceTheCRLFNote() {
        let ids = check("a\nb\n", facts: .init(lineEnding: .crlf, mixedLineEndings: true)).map(\.id)
        #expect(ids.contains(RulesHintProvider.mixedEndingsID))
        #expect(!ids.contains(RulesHintProvider.crlfID))
        #expect(!check("a\nb\n", facts: .init(lineEnding: .crlf)).map(\.id).contains(RulesHintProvider.mixedEndingsID))
    }

    @Test func mixedIndentFollowsTheMajority() throws {
        let text = "a:\n\tb\n\tc\n    d\n\te\n"
        let h = try #require(find(RulesHintProvider.mixedIndentID, text))
        #expect(h.title == "Mixed tabs and spaces. Convert to tabs?")
        #expect(apply(h, to: text) == "a:\n\tb\n\tc\n\td\n\te\n")
        // A Makefile keeps its tabs even when spaces win.
        let make = "all:\n\tcc a.c\n    x\n    y\n"
        let m = try #require(find(RulesHintProvider.mixedIndentID, make, fileName: "Makefile"))
        #expect(apply(m, to: make) == "all:\n\tcc a.c\n\tx\n\ty\n")
    }

    @Test func titlesFitAndNothingFiresOnOrdinaryText() {
        let prose = "Dinner plans\n\nWe could go to the place on Main Street. It has good reviews. Or we cook at home, which is cheaper.\n"
        let swift = "import Foundation\n\nstruct A {\n    let x = [1, 2, 3]\n    func f() -> Int { x.count }\n}\n"
        #expect(check(prose).isEmpty)
        #expect(check(swift, language: "swift", fileName: "A.swift").isEmpty)
        #expect(check("{\n  \"a\": [1, 2]\n}\n", language: "json", fileName: "a.json").isEmpty)
        // Every new title fits the bubble.
        let busy = "<<<<<<< a\n=======\n>>>>>>> b\nthe the end.  One. Two.  Three. Four.\n" + "AK" + "IA" + String(repeating: "FAKE", count: 4)
        for h in check(busy) + check("x = (1]\nprint(“a”)\n", language: "python") { #expect(h.title.count <= 60, "\(h.title)") }
    }

    @Test(.offPool) func rulesStayFastOnAFullWindow() {
        // The worst case the owl can hand them: 8 KB of dense code and of prose.
        let code = String(String(repeating: "f(a[\"(\"], {b: `${c}`}) // “x”\n", count: 400).utf16.prefix(OwlContextWindow.byteCap))!
        let prose = String(String(repeating: "the the word.  Next one. ", count: 400).utf16.prefix(OwlContextWindow.byteCap))!
        // Best of 10 per kind, not the mean of all 20: one descheduling in a
        // 20-check mean pushed it to 53.5 ms on GitHub's macos-15 runner (run
        // 45249676267). In this thread's CPU time, scaled by how slow the
        // machine is right now (see `Timing`): on a slow runner every try is
        // slow. The 50 ms bound is unchanged (single-digit ms locally); a rule
        // that blows up on a full 8 KB window misses it on every try. The wall
        // clock keeps a wide bound against a blow-up.
        let codeTime = Timing.best(of: 10) { _ = check(code, language: "javascript", fileName: "a.js") }
        let proseTime = Timing.best(of: 10) { _ = check(prose) }
        #expect(codeTime.scaled < 0.05, "code: best of 10 \(codeTime.description) per check")
        #expect(proseTime.scaled < 0.05, "prose: best of 10 \(proseTime.description) per check")
        #expect(codeTime.wall < 2 && proseTime.wall < 2, "code: \(codeTime.description); prose: \(proseTime.description)")
    }

    func windowContext(_ text: String, language: String, textStart: Int = 0) -> OwlContext {
        OwlContext(fileName: nil, language: language, text: text, textStart: textStart, visibleRange: NSRange(location: 0, length: 0),
                   selection: nil, documentID: UUID(), editGeneration: 0, isWholeDocument: false)
    }

    @Test func longOneLineJSONIsFormattedWhole() throws {
        let item = "{\"id\": 12345, \"name\": \"something\", \"tags\": [\"a\", \"b\"]}"
        let full = "[" + Array(repeating: item, count: 300).joined(separator: ",") + "]\n"
        #expect((full as NSString).length > OwlContextWindow.byteCap)
        let window = OwlContextWindow(text: full as NSString, visible: NSRange(location: 0, length: 100), selection: nil,
                                      fileName: "big.json", language: "json", documentID: UUID(), editGeneration: 0)
        #expect(!window.isWholeDocument && !window.context.isWholeDocument)
        let hints = rules.check(window.context, facts: .init(isWholeDocument: false))
        let h = try #require(hints.first { $0.id == RulesHintProvider.jsonID })
        // No replacement of the window: the app formats the whole file on Fix it.
        #expect(h.replacement == nil && h.range == nil && h.detail?.contains("whole file") == true)
        // No "doesn't parse" from the cut-off window either.
        #expect(!hints.contains { $0.id == RulesHintProvider.jsonInvalidID })
        // The whole-file format: valid, pretty, final newline kept; invalid says why.
        let pretty = try RulesHintProvider.formatWholeJSON(full).get()
        #expect(pretty.hasPrefix("[\n  {\n    \"id\": 12345") && pretty.hasSuffix("]\n"))
        let broken = String(full.dropLast(3)) + "\n"
        if case .success = RulesHintProvider.formatWholeJSON(broken) { Issue.record("a broken file was formatted") }
        // Not for a window further down, nor for something that isn't JSON-shaped.
        #expect(!RulesHintProvider.startsLongOneLineJSON(windowContext(String(full.prefix(8000)), language: "json", textStart: 500)))
        #expect(!RulesHintProvider.startsLongOneLineJSON(windowContext("hello " + String(full.prefix(8000)), language: "json")))
    }

    @Test func fixesOnAWindowSaySo() throws {
        let text = (1...6).map { "line \($0)   " }.joined(separator: "\n") + "\n"
        let whole = try #require(find(RulesHintProvider.trailingID, text))
        #expect(whole.detail?.contains("on screen") == false)
        let part = try #require(find(RulesHintProvider.trailingID, text, facts: .init(isWholeDocument: false)))
        #expect(part.detail?.contains("Only the part of the file around what’s on screen is changed.") == true)
    }

    @Test func csvTablesGetNoWhitespaceHints() {
        // Leading tabs are empty first fields, trailing ones empty last fields.
        let tsv = "name\tqty\tnote\t\n\tx\t \t\n  a\t2\t\t\nb \t3\t \t\nc\t4\t\t\nd\t5\t\t\ne\t6\t \t\n"
        #expect(find(RulesHintProvider.mixedIndentID, tsv) != nil || find(RulesHintProvider.trailingID, tsv) != nil) // as Plain Text they would fire
        for (text, name) in [(tsv, "a.tsv"), ("Dear Sir,,\nrow,1  \nrow,2  \nrow,3  \nrow,4  \nrow,5  \n", "a.csv")] {
            let ids = check(text, language: "csv", fileName: name).map(\.id)
            #expect(!ids.contains(RulesHintProvider.mixedIndentID), "\(name)")
            #expect(!ids.contains(RulesHintProvider.trailingID), "\(name)")
            #expect(!ids.contains(RulesHintProvider.letterID), "\(name)")
        }
    }
}
