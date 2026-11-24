import Foundation
import Testing
@testable import CedricCore

/// Edit validation (0.5.3): the proposal applied to a copy of the document,
/// then parsed and checked. Hard problems turn Apply off; warnings don't.
/// Only what the edit adds counts.
@Suite struct OwlEditValidationTests {
    static let inventory = """
    import Foundation

    struct Item {
        let name: String
        var count: Int
    }

    final class Inventory {
        private var items: [String: Item] = [:]

        func add(_ name: String, count: Int) {
            if var existing = items[name] {
                existing.count += count
                items[name] = existing
            } else {
                items[name] = Item(name: name, count: count)
            }
        }

        // BUG: removes even when count would go negative
        func remove(_ name: String, count: Int) {
            items[name]!.count -= count
        }

        func total() -> Int {
            var t = 0
            for (_, i) in items { t += i.count }
            return t
        }
    }

    """

    static let appJS = """
    const express = require('express');
    const app = express();

    function debounce(fn, ms) {
      let t;
      return (...args) => {
        clearTimeout(t);
        t = setTimeout(() => fn(...args), ms);
      };
    }

    app.get('/user/:id', async (req, res) => {
      const user = await db.find(req.params.id);
      res.send('<h1>' + user.name + '</h1>');   // FIXME: XSS
    });

    for (var i = 0; i < 3; i++) {
      setTimeout(() => console.log(i), 10);
    }

    app.listen(3000);

    """

    static let readonlyMD = """
    # Read-only

    This file is read-only. Try editing it.

    """

    static let brokenJSON = """
    {
      "name": "demo",
      "items": [1, 2, 3,],
      "ok": true
    }

    """

    static func check(_ text: String, _ language: String, _ fileName: String, find: String, replace: String) throws -> OwlEditProposal {
        let s = OwlDocumentSnapshot(text: text, generation: 1, fileName: fileName, language: language)
        var p = try OwlEditProposal.anchored(find: find, replace: replace, in: s).get()
        p.check = OwlEditValidation.validate(p, in: s, script: nil)
        return p
    }

    // MARK: inventory.swift

    @Test func swiftLetMutationIsAWarningWithApplyOn() throws {
        let p = try Self.check(Self.inventory, "swift", "inventory.swift", find: "items[name]!.count -= count",
                               replace: "guard let item = items[name] else { return };\nif item.count < count { return }\nitem.count -= count")
        #expect(!p.check.failsValidation)
        #expect(p.check.warnings.map(\.check) == [.swiftLetMutation])
        let w = try #require(p.check.warningText)
        #expect(w.contains("`item` is a `let`") && w.contains("if it’s a struct this won’t build"))
        #expect(w.contains("`items[name]?.count -= …`"))
        #expect(p.check.warnings.first?.line == 24)
        let text = Self.inventory as NSString
        #expect(p.canApply(text: text, generation: 1))
        #expect(p.state(text: text, generation: 1) == .ready(text.range(of: "items[name]!.count -= count")))
    }

    @Test func droppingABraceFailsTheBracketCheck() throws {
        let p = try Self.check(Self.inventory, "swift", "inventory.swift", find: "items[name]!.count -= count",
                               replace: "guard let item = items[name] else { return ;\nitem.count -= count")
        #expect(p.check.hardIssue?.check == .brackets)
        #expect(p.check.failureText?.hasPrefix("Doesn’t parse: ") == true)
        #expect(!p.canApply(text: Self.inventory as NSString, generation: 1))
        guard case .failsValidation(let why) = p.state(text: Self.inventory as NSString, generation: 1) else {
            Issue.record("Apply should be off"); return
        }
        #expect(why.hasPrefix("Doesn’t parse"))
        // The refresh the panel runs agrees.
        #expect(OwlEditProposal.refresh([p], text: Self.inventory as NSString, generation: 1, readOnly: false).states
                == [.failsValidation(why)])
    }

    @Test func theCorrectFixHasNoWarning() throws {
        let p = try Self.check(Self.inventory, "swift", "inventory.swift", find: "items[name]!.count -= count",
                               replace: "guard let item = items[name], item.count >= count else { return }\n        items[name]?.count -= count")
        #expect(p.check == .clean)
        #expect(p.check.warningText == nil && p.check.failureText == nil)
    }

    @Test func ifVarAndSwiftLetIdiomsDoNotWarn() throws {
        let p = try Self.check(Self.inventory, "swift", "inventory.swift", find: "existing.count += count",
                               replace: "existing.count += max(0, count)")
        #expect(p.check == .clean)
        #expect(OwlEditValidation.swiftLetMutations(Self.inventory).isEmpty)
        let idioms = "if let x = x { print(x) }\nguard let y = y else { return }\nif let z { use(z) }\nlet w = w\nvar v = v\n"
        #expect(OwlEditValidation.ruleIssues(language: "swift", original: "a()", replacement: idioms, firstLine: 1).isEmpty)
        // Reassigning the let name itself is a warning too.
        let re = OwlEditValidation.ruleIssues(language: "swift", original: "a()", replacement: "let n = 1\nn += 2", firstLine: 1)
        #expect(re.map(\.check) == [.swiftLetMutation] && re.allSatisfy { $0.severity == .warning })
        // Deferred initialisation of a typed let is legal.
        #expect(OwlEditValidation.ruleIssues(language: "swift", original: "a()", replacement: "let n: Int\nif ok { n = 1 } else { n = 2 }",
                                             firstLine: 1).isEmpty)
        // Only what the edit adds: the same let mutation before and after isn't new.
        let same = "let item = items[k]!\nitem.count -= 1"
        #expect(OwlEditValidation.ruleIssues(language: "swift", original: same, replacement: same + "\nprint(1)", firstLine: 1).isEmpty)
    }

    // MARK: app.js (the JavaScriptCore part is in CedricAITests)

    @Test func constSelfInitIsHard() throws {
        let p = try Self.check(Self.appJS, "javascript", "app.js", find: "  setTimeout(() => console.log(i), 10);\n}",
                               replace: "  const i = i;\n  setTimeout(() => console.log(i), 10);\n}")
        #expect(p.check.hardIssue?.check == .selfInitialization)
        #expect(p.check.hardIssue?.line == 18)
        #expect(p.check.failureText?.hasPrefix("Won’t run: ") == true)
        #expect(p.check.retryFeedback?.contains("fix it and call propose_edit again") == true)
        #expect(!p.canApply(text: Self.appJS as NSString, generation: 1))
    }

    @Test func varSelfInitAndSelfAssignmentAreWarnings() {
        let v = OwlEditValidation.ruleIssues(language: "javascript", original: "x();", replacement: "var x = x;", firstLine: 1)
        #expect(v.map(\.severity) == [.warning] && v.first?.check == .selfInitialization)
        let a = OwlEditValidation.ruleIssues(language: "c", original: "f();", replacement: "  total = total;", firstLine: 1)
        #expect(a.map(\.check) == [.selfAssignment] && a.first?.severity == .warning)
        let py = OwlEditValidation.ruleIssues(language: "python", original: "pass", replacement: "x = x", firstLine: 1)
        #expect(py.map(\.check) == [.selfAssignment])
        // Keyword arguments, comparisons, strings and members are not self-assignment.
        for code in ["f(x=x)", "if x == x:", "s = \"x = x\"", "self.x = x", "a = b"] {
            #expect(OwlEditValidation.ruleIssues(language: "python", original: "pass", replacement: code, firstLine: 1).isEmpty, "\(code)")
        }
    }

    @Test func letLoopVariablePasses() throws {
        let p = try Self.check(Self.appJS, "javascript", "app.js", find: "for (var i = 0;", replace: "for (let i = 0;")
        #expect(p.check == .clean)
    }

    @Test func anUnclosedCallFailsTheBracketCheck() throws {
        let p = try Self.check(Self.appJS, "javascript", "app.js", find: "setTimeout(() => console.log(i), 10);",
                               replace: "setTimeout(() => console.log(i), 10;")
        #expect(p.check.hardIssue?.check == .brackets)
        // The "(" opened on line 18 meets the loop's "}" on line 19.
        #expect(p.check.hardIssue?.line == 18)
        #expect(p.check.hardIssue?.message == "“(” isn’t closed before the “}” on line 19")
    }

    @Test func bracketsInStringsAndCommentsDoNotCount() {
        #expect(OwlEditValidation.bracketProblems("let s = \"(\" // )\nf(s)\n", language: .swift).isEmpty)
        #expect(OwlEditValidation.bracketProblems("f(a]\n", language: .javascript).count == 1)
        // Already unbalanced: only getting worse fails.
        let before = "func a() {\n"
        let same = OwlEditValidation.validate(language: "swift", fileName: "a.swift", before: before, after: "func b() {\n",
                                              original: "a", replacement: "b", script: nil)
        #expect(same == .clean)
        let worse = OwlEditValidation.validate(language: "swift", fileName: "a.swift", before: before, after: "func b() {\n(\n",
                                               original: "a", replacement: "b", script: nil)
        #expect(worse.hardIssue?.check == .brackets)
        // Regex literals, template literals and triple-quoted strings, over the whole text.
        #expect(OwlEditValidation.bracketProblems("const re = /\\(/;\n", language: .javascript).isEmpty)
        #expect(OwlEditValidation.bracketProblems("const re = /[(]/;\n", language: .javascript).isEmpty)
        #expect(OwlEditValidation.bracketProblems("const s = `hello {`;\n", language: .javascript).isEmpty)
        #expect(OwlEditValidation.bracketProblems("s = \"\"\"\n( [ {\n\"\"\"\nf(s)\n", language: .python).isEmpty)
        #expect(OwlEditValidation.bracketProblems("let r = /[(]/\n", language: .swift).isEmpty)
        #expect(OwlEditValidation.bracketProblems("let r = #/[(]/#\n", language: .swift).isEmpty)
        // A string past the highlighter's 20,000-unit line limit is still a string.
        let long = "const s = \"" + String(repeating: "a", count: 25_000) + "(\";\n"
        #expect(OwlEditValidation.bracketProblems(long, language: .javascript).isEmpty)
        // The same edits through validate: Apply stays on.
        for (lang, file, text) in [("javascript", "a.js", "const re = /\\(/;\n"), ("swift", "a.swift", "let r = /[(]/\n"),
                                   ("javascript", "a.js", "const s = `hello {`;\n")] {
            let c = OwlEditValidation.validate(language: lang, fileName: file, before: "", after: text,
                                               original: "", replacement: text, script: nil)
            #expect(!c.failsValidation, "\(text)")
        }
    }

    struct FakeScript: OwlScriptSyntaxChecker {
        var accepts: Bool
        func syntaxError(in script: String) -> OwlSyntaxError? { accepts ? nil : OwlSyntaxError(message: "SyntaxError", line: 1) }
    }

    @Test func javaScriptTheCheckerAcceptsIsNotFailedOnBrackets() {
        // An unbalanced count the lexer gets wrong can't block Apply once the parser accepts the text.
        let after = "f(a]\n"
        let ok = OwlEditValidation.validate(language: "javascript", fileName: "a.js", before: "f(a)\n", after: after,
                                            original: ")", replacement: "]", script: FakeScript(accepts: true))
        #expect(ok == .clean)
        let bad = OwlEditValidation.validate(language: "javascript", fileName: "a.js", before: "", after: after,
                                             original: "", replacement: after, script: FakeScript(accepts: false))
        #expect(bad.hardIssue?.check == .script)
    }

    @Test func rubyBracketsOnlyWarn() {
        // `%q{ hello ( }` is a string the highlighter doesn't know: a warning, Apply on.
        let after = "s = %q{ hello ( }\n"
        let c = OwlEditValidation.validate(language: "ruby", fileName: "a.rb", before: "s = 1\n", after: after,
                                           original: "1", replacement: "%q{ hello ( }", script: nil)
        #expect(!c.failsValidation)
        #expect(c.warnings.map(\.check) == [.brackets])
    }

    // MARK: readonly.md

    @Test func addingANegationWarnsWithApplyOn() throws {
        let p = try Self.check(Self.readonlyMD, "markdown", "readonly.md", find: "Try editing it.", replace: "Editing this file is not permitted.")
        #expect(!p.check.failsValidation)
        #expect(p.check.warnings.map(\.check) == [.negation])
        #expect(p.check.warningText == "May change the meaning: adds “not”")
        #expect(p.canApply(text: Self.readonlyMD as NSString, generation: 1))
        let q = try Self.check(Self.readonlyMD, "markdown", "readonly.md", find: "Try editing it.", replace: "Please try editing it.")
        #expect(q.check == .clean)
    }

    @Test func negationCountsContractionsAndDrops() {
        #expect(OwlEditValidation.negationChange(original: "It never fails.", replacement: "It fails.") == "May change the meaning: drops “never”")
        #expect(OwlEditValidation.negationChange(original: "You can go.", replacement: "You can’t go.") == "May change the meaning: adds “can't”")
        #expect(OwlEditValidation.negationChange(original: "Do not run.", replacement: "Don't run.") == nil)
        #expect(OwlEditValidation.negationChange(original: "Smoking is allowed.", replacement: "Smoking is prohibited.") != nil)
        #expect(OwlEditValidation.negations(in: "Nobody, nothing, nowhere; neither nor none. Cannot go without it.").count == 8)
    }

    // MARK: broken.json

    @Test func jsonIsDifferential() throws {
        let fixed = try Self.check(Self.brokenJSON, "json", "broken.json", find: "[1, 2, 3,]", replace: "[1, 2, 3]")
        #expect(fixed.check == .clean)
        // Elsewhere in a document that was already invalid: not the edit's fault.
        let elsewhere = try Self.check(Self.brokenJSON, "json", "broken.json", find: "\"demo\"", replace: "\"demo2\"")
        #expect(elsewhere.check == .clean)
        // On a valid document, a trailing comma is the edit's.
        let valid = Self.brokenJSON.replacingOccurrences(of: "3,]", with: "3]")
        let broken = try Self.check(valid, "json", "ok.json", find: "[1, 2, 3]", replace: "[1, 2, 3,]")
        #expect(broken.check.hardIssue?.check == .json)
        #expect(broken.check.hardIssue?.line == 3)
        #expect(broken.check.failureText?.hasPrefix("Doesn’t parse: ") == true)
    }

    @Test func aNewErrorInAnAlreadyBrokenDocumentStillCounts() {
        // Removing the trailing comma and the "]": a different complaint, so it counts.
        let before = "{ \"items\": [1, 2,] }"
        let after = "{ \"items\": [1, 2 }"
        let c = OwlEditValidation.validate(language: "json", fileName: "a.json", before: before, after: after,
                                           original: "[1, 2,]", replacement: "[1, 2", script: nil)
        #expect(c.hardIssue?.check == .json)
        // The same complaint as before: still not the edit's.
        let same = OwlEditValidation.validate(language: "json", fileName: "a.json",
                                               before: "{\"a\": 1, \"b\": [1,]}\n", after: "{\"a\": 1, \"b\": [1,]}\n",
                                               original: "", replacement: "", script: nil)
        #expect(same == .clean)
        // The same complaint, but now in the replacement while the old one wasn't in the replaced text: counts.
        let script = FakeLineScript()
        let inEdit = OwlEditValidation.validate(language: "javascript", fileName: "a.js", before: "x(\nok\nok\n", after: "x(\nok\nbad\n",
                                                original: "ok", replacement: "bad", firstLine: 3, script: script)
        #expect(inEdit.hardIssue?.check == .script && inEdit.hardIssue?.line == 3)
    }

    @Test func aPartialFixOfABrokenJSONDocumentStaysClean() {
        // The parser stopped at the missing value; filling it in uncovers the
        // trailing comma that was already there. Not the edit's: Apply stays on.
        let before = "{ \"a\": , \"items\": [1,] }"
        let after = "{ \"a\": 1, \"items\": [1,] }"
        let c = OwlEditValidation.validate(language: "json", fileName: "a.json", before: before, after: after,
                                           original: "\"a\": ,", replacement: "\"a\": 1,", script: nil)
        #expect(c == .clean)
        // The same over several lines, with the old error on a later line.
        let mb = "{\n  \"a\": ,\n  \"items\": [1,]\n}\n"
        let ma = "{\n  \"a\": 1,\n  \"items\": [1,]\n}\n"
        let m = OwlEditValidation.validate(language: "json", fileName: "a.json", before: mb, after: ma,
                                           original: "  \"a\": ,\n", replacement: "  \"a\": 1,\n", firstLine: 2, script: nil)
        #expect(m == .clean)
    }

    @Test func aNewInvalidValueWithTheSameWordingCounts() {
        // Both "Invalid value", but the new one is where the edit typed it.
        let before = "{\"a\": 1,\n\"b\": ,\n\"c\": 3}\n"
        let after = "{\"a\": x,\n\"b\": ,\n\"c\": 3}\n"
        #expect(OwlEditValidation.comparable(OwlEditValidation.jsonError(before)!.message)
                == OwlEditValidation.comparable(OwlEditValidation.jsonError(after)!.message))
        let c = OwlEditValidation.validate(language: "json", fileName: "a.json", before: before, after: after,
                                           original: "1", replacement: "x", script: nil)
        #expect(c.hardIssue?.check == .json)
        #expect(c.hardIssue?.line == 1)
    }

    @Test func serializationErrorsHaveALineAndAnOffset() {
        let e = OwlEditValidation.jsonError("{\n \"é\": 1,\n \"b\": x }")
        #expect(e?.line == 3)
        #expect(e?.offset == ("{\n \"é\": 1,\n \"b\": " as NSString).length)
        // An older system's wording: no line in the message, so from the offset.
        let ns = NSError(domain: NSCocoaErrorDomain, code: 3840, userInfo: [NSDebugDescriptionErrorKey: "Invalid value around character 9."])
        let old = OwlEditValidation.syntaxError(from: ns, fallback: "x", in: "{\"a\":\n  ,}")
        #expect(old.message == "Invalid value")
        #expect(old.offset == 9 && old.line == 2)
        #expect(OwlEditValidation.trailingComma("[1,\n2,]")?.offset == 5)
    }

    @Test func aFinalNewlineEndsTheLastEditedLine() {
        #expect(OwlEditValidation.lines("a\n", firstLine: 3) == 3...3)
        #expect(OwlEditValidation.lines("a\nb", firstLine: 3) == 3...4)
        #expect(OwlEditValidation.lines("", firstLine: 3) == 3...3)
        #expect(OwlEditValidation.lines("a\nb\n", firstLine: 1) == 1...2)
    }

    /// Always "Unexpected token": on the line of the first "bad", else line 1.
    struct FakeLineScript: OwlScriptSyntaxChecker {
        func syntaxError(in script: String) -> OwlSyntaxError? {
            let lines = script.components(separatedBy: "\n")
            return OwlSyntaxError(message: "Unexpected token", line: (lines.firstIndex(of: "bad") ?? 0) + 1)
        }
    }

    // MARK: Property lists and XML

    static let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Name</key>
        <string>Demo</string>
    </dict>
    </plist>

    """

    @Test func plistPassesAndFails() throws {
        let ok = try Self.check(Self.plist, "xml", "Info.plist", find: "<string>Demo</string>", replace: "<string>Demo 2</string>")
        #expect(ok.check == .clean)
        let bad = try Self.check(Self.plist, "xml", "Info.plist", find: "<string>Demo</string>", replace: "<string>Demo</strin>")
        #expect(bad.check.hardIssue?.check == .plist)
    }

    static let xml = """
    <?xml version="1.0"?>
    <!DOCTYPE note [ <!ENTITY ext SYSTEM "http://127.0.0.1:9/never-fetched.txt"> ]>
    <note>
      <to>Tove</to>
    </note>

    """

    @Test func aUsedExternalEntityIsNotFetched() throws {
        // `&ext;` is used, and names a local file whose text is a marker. The
        // validation's parser never reads it: no marker in the parsed text,
        // and the check returns at once (no error: the entity is skipped).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-xml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("ent.txt")
        try Data("EXTERNAL-MARKER".utf8).write(to: file)
        for url in [file.absoluteString, "http://127.0.0.1:9/never-fetched.txt"] {
            let doc = """
            <?xml version="1.0"?>
            <!DOCTYPE note [ <!ENTITY ext SYSTEM "\(url)"> ]>
            <note>&ext;</note>

            """
            let started = Date()
            #expect(OwlEditValidation.xmlError(doc) == nil)
            #expect(Date().timeIntervalSince(started) < 2)
            let p = OwlEditValidation.xmlParser(for: Data(doc.utf8))
            let text = TextCollector()
            p.delegate = text
            _ = p.parse()
            #expect(!text.text.contains("EXTERNAL-MARKER"))
        }
    }

    final class TextCollector: NSObject, XMLParserDelegate {
        var text = ""
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    }

    @Test func xmlPassesAndFailsWithoutExternalEntities() throws {
        #expect(OwlEditValidation.xmlParser(for: Data(Self.xml.utf8)).shouldResolveExternalEntities == false)
        let ok = try Self.check(Self.xml, "xml", "note.xml", find: "<to>Tove</to>", replace: "<to>Jani</to>")
        #expect(ok.check == .clean)
        let bad = try Self.check(Self.xml, "xml", "note.xml", find: "<to>Tove</to>", replace: "<to>Tove</from>")
        #expect(bad.check.hardIssue?.check == .xml)
        #expect(bad.check.hardIssue?.line == 4)
    }

    // MARK: The gate

    @Test func gateRefusesTheFirstHardFailureOnceThenMarks() throws {
        let valid = Self.brokenJSON.replacingOccurrences(of: "3,]", with: "3]")
        let s = OwlDocumentSnapshot(text: valid, generation: 1, fileName: "ok.json", language: "json")
        var gate = OwlEditGate(script: nil)
        let bad = try OwlEditProposal.anchored(find: "[1, 2, 3]", replace: "[1, 2, 3,]", in: s).get()
        guard case .retry(let feedback) = gate.review(bad, in: s) else { Issue.record("not refused"); return }
        #expect(feedback.hasPrefix("the change doesn't parse: ") && feedback.contains("(line 3)")
                && feedback.hasSuffix("fix it and call propose_edit again"))
        guard case .propose(let marked) = gate.review(bad, in: s) else { Issue.record("not marked"); return }
        #expect(marked.check.failsValidation && !marked.canApply(text: valid as NSString, generation: 1))
        let good = try OwlEditProposal.anchored(find: "\"demo\"", replace: "\"demo2\"", in: s).get()
        guard case .propose(let fine) = gate.review(good, in: s) else { Issue.record("refused a valid edit"); return }
        #expect(fine.check == .clean)
    }

    @Test func theRefusalSummaryMatchesTheCardTitle() throws {
        let text = "let a = 1;\n"
        let s = OwlDocumentSnapshot(text: text, generation: 1, fileName: "a.js", language: "javascript")
        var gate = OwlEditGate(script: nil)
        let p = try OwlEditProposal.anchored(find: "let a = 1;", replace: "const a = a;", in: s).get()
        let r = gate.screen(OwlToolResult(text: "proposed", proposal: p, summary: "Proposed an edit", ok: true), in: s)
        #expect(!r.ok)
        #expect(r.summary == "Won’t run")
        var gate2 = OwlEditGate(script: nil)
        let q = try OwlEditProposal.anchored(find: "let a = 1;", replace: "let a = (1;", in: s).get()
        #expect(gate2.screen(OwlToolResult(text: "proposed", proposal: q, summary: "Proposed an edit", ok: true), in: s).summary == "Doesn’t parse")
    }

    @Test func noCompilesOrVerifiedWording() {
        let texts = [OwlEditCheck(issues: [OwlEditIssue(check: .json, severity: .hard, message: "m", line: 1)]).failureText,
                     OwlEditCheck(issues: [OwlEditIssue(check: .selfInitialization, severity: .hard, message: "m")]).retryFeedback,
                     OwlEditCheck.clean.failureText, OwlEditCheck.clean.warningText].compactMap { $0 }
        for t in texts { #expect(!t.lowercased().contains("compiles") && !t.lowercased().contains("verified"), "\(t)") }
    }
}
