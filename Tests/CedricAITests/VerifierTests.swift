import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// The verifier between the model and the owl, the cited-line check, the
/// fix rules and the source names.
@Suite struct VerifierTests {
    static let derekHTML = "<html>\n<head>\n<title>Test</title>\n<body>\nTest\n</body>\n</html>"

    func json(_ hints: [[String: Any]]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["hints": hints]), encoding: .utf8)!
    }

    @Test func ownersValidHTMLGetsNoTagHint() {
        // What Apple Intelligence said on Derek's Mac, with and without a category.
        for category: Any in ["unclosed-tag", "other", NSNull()] {
            var h: [String: Any] = ["kind": "warning", "title": "Missing closing tag",
                                    "detail": "The `<html>` tag is not closed, which may cause parsing issues.",
                                    "line": 1, "find": "<html>", "replacement": "", "confidence": 0.8]
            if !(category is NSNull) { h["category"] = category }
            #expect(HintPrompt.parse(json([h]), text: Self.derekHTML, source: "apple", language: "html").isEmpty)
        }
        #expect(TagScan.scan(Self.derekHTML).unclosed.isEmpty)
        #expect(TagScan.scan(Self.derekHTML).stray.isEmpty)
    }

    @Test func aRealUnclosedTagIsKeptAndItsFixMustBalance() {
        let html = "<div class=\"card\">\n<p>Hello\n<span>name\n</div>"
        #expect(TagScan.scan(html).unclosed == ["span"])
        let good: [String: Any] = ["kind": "fix", "category": "unclosed-tag", "title": "Unclosed <span>",
                                   "detail": "The `<span>` is never closed.", "line": 3,
                                   "find": "<span>name", "replacement": "<span>name</span>", "confidence": 0.9]
        let hints = HintPrompt.parse(json([good]), text: html, source: "local:x", language: "html")
        #expect(hints.count == 1)
        #expect(hints.first?.replacement == "<span>name</span>")
        // A "fix" that doesn't close it: the hint stays, the Apply doesn't.
        var bad = good; bad["replacement"] = "<span >name"
        let kept = HintPrompt.parse(json([bad]), text: html, source: "local:x", language: "html")
        #expect(kept.count == 1 && kept.first?.replacement == nil)
    }

    @Test func tagScanIgnoresVoidCommentsDoctypeAndScripts() {
        let html = """
        <!DOCTYPE html>
        <!-- <div> not a tag -->
        <html><head><meta charset="utf-8"><link rel="x"></head>
        <body><img src="a.png"><br><input type="text"/>
        <script>if (a < b && c > d) { document.write("<div>") }</script>
        <ul><li>one<li>two</ul>
        </body></html>
        """
        let r = TagScan.scan(html)
        #expect(r.unclosed.isEmpty && r.stray.isEmpty)
        #expect(TagScan.scan("<a><b></a></b>", html: false).problemCount > 0)   // XML is strict
    }

    @Test func bracketClaimsAreChecked() {
        let swift = "let s = \"(not a paren\" // ) neither\nlet x = f(a, [1, 2], { $0 })\n"
        #expect(BracketScan.scan(swift, language: "swift").isBalanced)
        let claim: [String: Any] = ["kind": "fix", "category": "brackets", "title": "Missing closing parenthesis",
                                    "detail": "The call to f is never closed.", "line": 2, "find": "f(a, [1, 2], { $0 })",
                                    "replacement": "f(a, [1, 2], { $0 }))", "confidence": 0.9]
        #expect(HintPrompt.parse(json([claim]), text: swift, source: "apple", language: "swift").isEmpty)

        let broken = "let x = f(a, [1, 2]\nprint(x)\n"
        #expect(!BracketScan.scan(broken, language: "swift").isBalanced)
        var real = claim; real["find"] = "f(a, [1, 2]"; real["line"] = 1; real["replacement"] = "f(a, [1, 2])"
        let hints = HintPrompt.parse(json([real]), text: broken, source: "apple", language: "swift")
        #expect(hints.count == 1 && hints.first?.replacement == "f(a, [1, 2])")

        let py = "s = 'it''s'  # (\nprint(s)\n"
        #expect(BracketScan.scan(py, language: "python").isBalanced)
        #expect(!BracketScan.scan("s = \"open\nprint(s)", language: "python").isBalanced)
    }

    @Test func unusedAndUndefinedClaimsAreChecked() {
        let code = "let total = 3\nprint(total)\n"
        let unused: [String: Any] = ["kind": "warning", "category": "unused", "title": "Unused variable",
                                     "detail": "The variable `total` is never used.", "line": 1, "find": "let total = 3",
                                     "replacement": "", "confidence": 0.8]
        #expect(HintPrompt.parse(json([unused]), text: code, source: "apple", language: "swift").isEmpty)
        let reallyUnused = "let total = 3\nprint(4)\n"
        #expect(HintPrompt.parse(json([unused]), text: reallyUnused, source: "apple", language: "swift").count == 1)

        let undefined: [String: Any] = ["kind": "warning", "category": "undefined", "title": "Undefined variable",
                                        "detail": "`total` is not defined.", "line": 2, "find": "print(total)",
                                        "replacement": "", "confidence": 0.8]
        #expect(HintPrompt.parse(json([undefined]), text: code, source: "apple", language: "swift").isEmpty)
        let reallyUndefined = "print(total)\n"
        #expect(HintPrompt.parse(json([undefined]), text: reallyUndefined, source: "apple", language: "swift").count == 1)
    }

    @Test func jsonClaimsAreChecked() {
        let valid = "{\"a\": [1, 2], \"b\": null}"
        let h: [String: Any] = ["kind": "fix", "category": "json", "title": "Invalid JSON: trailing comma",
                                "detail": "JSON does not allow trailing commas.", "line": 1, "find": "[1, 2]",
                                "replacement": "[1, 2,]", "confidence": 0.9]
        #expect(HintPrompt.parse(json([h]), text: valid, source: "apple", language: "json").isEmpty)
        let invalid = "{\"a\": [1, 2,], \"b\": null}"
        var fix = h; fix["find"] = "[1, 2,]"; fix["replacement"] = "[1, 2]"
        let hints = HintPrompt.parse(json([fix]), text: invalid, source: "apple", language: "json")
        #expect(hints.count == 1 && hints.first?.replacement == "[1, 2]")
    }

    @Test func snippetMustBeOnTheCitedLine() {
        let code = "let a = 1\nlet b = 2\nlet c = 3\nlet d = 4\nlet e = 5\nlet f = 6\nfor i in 0...n { }\n"
        var h: [String: Any] = ["kind": "fix", "category": "logic", "title": "Off by one",
                                "detail": "0...n runs one past.", "line": 7, "find": "0...n",
                                "replacement": "0..<n", "confidence": 0.9]
        #expect(HintPrompt.parse(json([h]), text: code, source: "apple", language: "swift").count == 1)
        h["line"] = 1      // cited far from where the snippet is
        #expect(HintPrompt.parse(json([h]), text: code, source: "apple", language: "swift").isEmpty)
        h["line"] = 6      // next to it is fine
        #expect(HintPrompt.parse(json([h]), text: code, source: "apple", language: "swift").count == 1)
        h["line"] = 7; h["find"] = "0...m"   // not in the code at all
        #expect(HintPrompt.parse(json([h]), text: code, source: "apple", language: "swift").isEmpty)
        h["find"] = "7| for i in 0...n"      // copied the line number: stripped
        h["replacement"] = "7| for i in 0..<n"
        let hints = HintPrompt.parse(json([h]), text: code, source: "apple", language: "swift")
        #expect(hints.first?.replacement == "for i in 0..<n")
    }

    @Test func fixableHintsRankFirstAndFixesStaySmall() {
        let code = "let x = items[items.count]\nlet y = 2\n"
        let prose: [String: Any] = ["kind": "warning", "category": "logic", "title": "Confusing name",
                                    "detail": "y says nothing.", "line": 2, "find": "let y = 2", "replacement": "", "confidence": 0.9]
        let fix: [String: Any] = ["kind": "fix", "category": "logic", "title": "Index out of range",
                                  "detail": "The last index is count - 1.", "line": 1, "find": "items[items.count]",
                                  "replacement": "items[items.count - 1]", "confidence": 0.9]
        let hints = HintPrompt.parse(json([prose, fix]), text: code, source: "apple", language: "swift")
        #expect(hints.map(\.title) == ["Index out of range", "Confusing name"])
        var huge = fix
        huge["replacement"] = "items[items.count - 1] // " + String(repeating: "items count ", count: 20)
        #expect(HintPrompt.parse(json([huge]), text: code, source: "apple", language: "swift").first?.replacement == nil)
    }

    @Test func promptAsksForLinesCategoriesAndFixes() {
        let user = OwlPrompts.user(for: context("a\nb"), text: "a\nb", model: "x")
        #expect(user.contains("1| a\n2| b"))
        let sys = OwlPrompts.system(for: .codeHints)
        #expect(sys.contains("line number") && sys.contains("category") && sys.contains("If you are unsure"))
        #expect(sys.contains("Give one whenever the problem can be fixed"))
        #expect(HintGrammar.gbnf.contains("category ::=") && HintGrammar.gbnf.contains("line ::="))
        #expect(!HintVerifier.isStrictJSON("{\"a\": [1, 2,]}") && HintVerifier.isStrictJSON("{\"a,]\": [1, 2]}"))
    }

    @Test func sourceDisplayNames() {
        #expect(HintSource.displayName("rules") == nil)
        #expect(HintSource.displayName("notice") == nil)
        #expect(HintSource.displayName("apple") == "AI suggestion · Apple Intelligence")
        #expect(HintSource.displayName("local:qwen2.5-coder-1.5b-instruct-mlx") == "AI suggestion · Qwen2.5 Coder 1.5B")
        #expect(HintSource.displayName("local:qwen/qwen3.6-35b-a3b") == "AI suggestion · Qwen3.6 35B A3b")
        #expect(HintSource.displayName("local:qwen2.5-coder-3b-instruct-q4_k_m", catalog: ModelCatalog.bundled())
                == "AI suggestion · Qwen2.5 Coder 3B")
    }

    @Test func jsonClaimsAboutAWindowAreDropped() {
        // The start of a long file: a fragment never parses, so "invalid JSON" can't be checked there.
        let fragment = "{\"items\": [{\"id\": 1, \"name\": \"a\"}, {\"id\": 2, \"na"
        let claim: [String: Any] = ["kind": "warning", "category": "json", "title": "Invalid JSON",
                                    "detail": "The JSON is not valid: it ends early.", "line": 1, "find": "\"na", "confidence": 0.9]
        #expect(HintPrompt.parse(json([claim]), text: fragment, source: "apple", language: "json", wholeDocument: false).isEmpty)
        // The same claim about a whole document that really is broken is kept.
        #expect(HintPrompt.parse(json([claim]), text: fragment, source: "apple", language: "json").count == 1)
    }

    // MARK: 0.3.0: the offline rules' categories

    @Test func everyOfflineRuleHasACategory() {
        let ids = RulesHintProvider.languageRuleIDs + [RulesHintProvider.secretID, RulesHintProvider.editorConfigIndentID,
                                                       RulesHintProvider.mixedIndentID, RulesHintProvider.trailingID, RulesHintProvider.crlfID]
        for id in ids { #expect(HintVerifier.ruleCategory[id] != nil, "\(id)") }
        // The model's choices (its JSON schema) don't change.
        #expect(HintVerifier.Category.modelCases.map(\.rawValue) == ["unclosed-tag", "brackets", "unused", "undefined", "json", "logic", "other"])
        let schema = HintPrompt.messages(for: OwlContext(fileName: "a.sql", language: "sql", text: "x", textStart: 0,
                                                         visibleRange: NSRange(location: 0, length: 0), selection: nil, documentID: UUID(),
                                                         editGeneration: 0), text: "x", model: "m", server: true)
        #expect(!schema.contains { $0.content.contains("null-compare") })
    }

    @Test func aiHintsThatRepeatAnOfflineRuleAreDropped() {
        let sql = "SELECT * FROM users WHERE email = NULL;\n"
        let claim: [String: Any] = ["kind": "fix", "category": "logic", "title": "Use IS NULL instead of = NULL",
                                    "detail": "Comparing with = NULL is never true.", "line": 1, "find": "email = NULL",
                                    "replacement": "email IS NULL", "confidence": 0.9]
        #expect(HintVerifier.categories(model: "logic", title: "Use IS NULL instead of = NULL", detail: nil).contains(.nullCompare))
        // The offline rule fires on this text: its hint (with its own Fix it) wins.
        #expect(HintPrompt.parse(json([claim]), text: sql, source: "apple", language: "sql").isEmpty)
        // Where no rule fires (a different claim, or text without the problem) the AI hint stays.
        let other: [String: Any] = ["kind": "warning", "category": "logic", "title": "Index the email column",
                                    "detail": "This lookup scans the table.", "line": 1, "find": "WHERE email", "confidence": 0.9]
        #expect(HintPrompt.parse(json([other]), text: sql, source: "apple", language: "sql").count == 1)
        #expect(!HintVerifier.duplicatesRule([.nullCompare], text: "SELECT * FROM users WHERE email IS NULL;\n", language: "sql"))
        #expect(HintVerifier.duplicatesRule([.secret], text: "k = \"" + "gh" + "p_" + String(repeating: "x", count: 36) + "\"\n", language: "python"))
        #expect(!HintVerifier.duplicatesRule([.logic], text: sql, language: "sql"))
    }

    /// What Apple Intelligence showed on a brand-new empty Plain Text
    /// document (0 words, 0 characters): there is no code block to be empty.
    @Test func emptyCodeBlockHintOnPlainTextIsRejected() {
        let hint: [String: Any] = ["kind": "warning", "category": "other", "title": "Empty code block",
                                   "detail": "The code has no content, which may cause errors in execution or parsing.",
                                   "line": 1, "find": "", "replacement": "", "confidence": 0.8]
        #expect(HintPrompt.parse(json([hint]), text: "", source: "apple", language: "plain").isEmpty)
        #expect(HintPrompt.parse(json([hint]), text: "   \n\t", source: "apple", language: "plain").isEmpty)
        let note = "Just a note."
        #expect(HintPrompt.parse(json([hint]), text: note, source: "apple", language: "plain").isEmpty)
        #expect(HintPrompt.parse(json([hint]), text: note, source: "apple", language: "markdown").isEmpty)
        // "fenced code" is the same claim.
        var fenced = hint
        fenced["title"] = "Fenced code is empty"
        #expect(HintPrompt.parse(json([fenced]), text: note, source: "apple", language: "plain").isEmpty)
        // Three spaces is not an indented code block.
        #expect(HintPrompt.parse(json([hint]), text: "   print(1)\n", source: "apple", language: "plain").isEmpty)

        // A real empty fence is still flagged, closed so the offline
        // unclosed-fence rule does not take the hint instead.
        for sample in ["```\n```\n", "```swift\n```\n", "~~~\n~~~\n", "Intro paragraph here.\n\n```\n```\n\nAfter.\n"] {
            let kept = HintPrompt.parse(json([hint]), text: sample, source: "apple", language: "markdown")
            #expect(kept.count == 1, "\(sample)")
            #expect(kept.first?.title == "Empty code block")
        }
        let indented = "    \n    \n"
        #expect(HintPrompt.parse(json([hint]), text: indented, source: "apple", language: "plain").isEmpty)
        let indentedCode = "    print(1)\n"
        #expect(HintPrompt.parse(json([hint]), text: indentedCode, source: "apple", language: "plain").count == 1)
        #expect(HintPrompt.parse(json([hint]), text: "\tprint(1)\n", source: "apple", language: "plain").count == 1)
        // A claim that does not invent a construct still stands.
        let prose: [String: Any] = ["kind": "tip", "category": "other", "title": "Missing a verb",
                                    "detail": "The sentence never says what happens.", "find": "Just a note.",
                                    "replacement": "", "confidence": 0.9]
        #expect(HintPrompt.parse(json([prose]), text: note, source: "apple", language: "plain").count == 1)
    }

    @Test func absentConstructsAreRejectedAndRealOnesStay() {
        let note = "Just a short note about the day."
        func claim(_ title: String, _ detail: String, find: String = "") -> [String: Any] {
            ["kind": "warning", "category": "other", "title": title, "detail": detail,
             "line": 1, "find": find, "replacement": "", "confidence": 0.9]
        }
        #expect(HintPrompt.parse(json([claim("Empty table", "The table has no rows.")]), text: note, source: "apple", language: "plain").isEmpty)
        #expect(HintPrompt.parse(json([claim("Broken link", "The link goes nowhere.")]), text: note, source: "apple", language: "markdown").isEmpty)
        #expect(HintPrompt.parse(json([claim("Skipped heading", "The heading level jumps.")]), text: note, source: "apple", language: "plain").isEmpty)
        #expect(HintPrompt.parse(json([claim("Empty list", "The list has no items.")]), text: note, source: "apple", language: "markdown").isEmpty)
        // The same words in SQL are about a database table, not a Markdown one.
        let sql = "SELECT * FROM users WHERE email IS NULL;\n"
        let scan = claim("Index the email column", "This lookup scans the table.", find: "WHERE email")
        #expect(HintPrompt.parse(json([scan]), text: sql, source: "apple", language: "sql").count == 1)

        let table = "| a | b |\n| --- | --- |\n| 1 | 2 |\n"
        #expect(HintPrompt.parse(json([claim("Wide table", "The table has two columns.")]), text: table, source: "apple", language: "markdown").count == 1)
        let linked = "See [the notes](https://example.com/notes) for the rest of it.\n"
        #expect(HintPrompt.parse(json([claim("Absolute link", "The link leaves this Mac.")]), text: linked, source: "apple", language: "markdown").count == 1)
        let headed = "# Notes\n\nHello there, this is a paragraph.\n"
        #expect(HintPrompt.parse(json([claim("Short heading", "The heading is one word.")]), text: headed, source: "apple", language: "markdown").count == 1)
        let setext = "Notes\n=====\n\nHello there, this is a paragraph.\n"
        #expect(HintPrompt.parse(json([claim("Short heading", "The heading is one word.")]), text: setext, source: "apple", language: "plain").count == 1)
        let list = "- apples\n- pears\n"
        #expect(HintPrompt.parse(json([claim("Short list", "The list has two items.")]), text: list, source: "apple", language: "markdown").count == 1)
    }

    @Test func quotedAndCitedTextMustBeInTheDocument() {
        let code = "let total = 3\nprint(total)\n"
        let invented: [String: Any] = ["kind": "warning", "category": "other", "title": "Unused name",
                                       "detail": "The variable `missingName` is never used.",
                                       "find": "", "replacement": "", "confidence": 0.9]
        #expect(HintPrompt.parse(json([invented]), text: code, source: "apple", language: "swift").isEmpty)
        let quoted: [String: Any] = ["kind": "warning", "category": "other", "title": "Odd sentence",
                                     "detail": "It says \"hello world\" where the file is silent.",
                                     "find": "", "replacement": "", "confidence": 0.9]
        #expect(HintPrompt.parse(json([quoted]), text: code, source: "apple", language: "swift").isEmpty)
        let curly: [String: Any] = ["kind": "warning", "category": "other", "title": "Odd sentence",
                                    "detail": "It says “hello world” where the file is silent.",
                                    "find": "", "replacement": "", "confidence": 0.9]
        #expect(HintPrompt.parse(json([curly]), text: code, source: "apple", language: "swift").isEmpty)
        let cited: [String: Any] = ["kind": "warning", "category": "logic", "title": "Odd name",
                                    "detail": "This snippet is confusing.", "find": "not in the file",
                                    "replacement": "", "confidence": 0.9]
        #expect(HintPrompt.parse(json([cited]), text: code, source: "apple", language: "swift").isEmpty)
        let real: [String: Any] = ["kind": "warning", "category": "other", "title": "Name is short",
                                   "detail": "The variable `total` is only assigned.", "find": "let total = 3",
                                   "replacement": "", "confidence": 0.9]
        #expect(HintPrompt.parse(json([real]), text: code, source: "apple", language: "swift").count == 1)
    }
}
