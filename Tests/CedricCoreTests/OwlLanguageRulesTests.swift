import Foundation
import Testing
@testable import CedricCore

/// 0.3.0's language rules, foundation: the code mask, the rule table's
/// gating (language, whole document, style tier), speed, and the clean
/// corpus every rule must stay quiet on.
@Suite struct OwlLanguageRulesTests {
    static let rules = RulesHintProvider()

    static func check(_ text: String, language: String, fileName: String? = nil, facts: OwlDocumentFacts = OwlDocumentFacts()) -> [OwlHint] {
        let ctx = OwlContext(fileName: fileName, language: language, text: text, textStart: 0,
                             visibleRange: NSRange(location: 0, length: 0), selection: nil, documentID: UUID(), editGeneration: 0)
        return rules.check(ctx, facts: facts)
    }

    /// Only the language rules' hints, through the provider (so order and gating are the real ones).
    static func languageIDs(_ text: String, language: String, fileName: String? = nil, facts: OwlDocumentFacts = OwlDocumentFacts()) -> [String] {
        let ids = Set(RulesHintProvider.languageRules.map(\.id))
        return check(text, language: language, fileName: fileName, facts: facts).map(\.id).filter(ids.contains)
    }

    // MARK: CodeMask

    @Test func maskBlanksStringsAndCommentsKeepingOffsets() throws {
        let py = "x = r\"\\d\"  # == None\ny = 'a'\n"
        let m = try #require(CodeMask.make(py as NSString, language: "python"))
        #expect((m.code as NSString).length == (py as NSString).length)
        #expect(m.code == "x = r\"  \"" + String(repeating: " ", count: 11) + "\ny = ' '\n")
        #expect(m.spans.count == 3)
        #expect(m.spans[0].prefix == "r")
        #expect(!m.isCode(6) && m.isCode(0) && !m.isCode(12))
        #expect(m.string(startingAt: 5)?.kind == .string)
        // JS: a regex literal and a template literal are masked; code between stays.
        let js = "const r = /debugger/; const t = `NaN ${a}`; // x === NaN\n"
        let jm = try #require(CodeMask.make(js as NSString, language: "javascript"))
        #expect(!jm.code.contains("debugger") && !jm.code.contains("NaN") && jm.code.contains("const t ="))
        #expect(CodeMask.make("a: 1" as NSString, language: "yaml") == nil)
    }

    @Test func shellMaskKnowsQuotesCommentsAndHeredocs() throws {
        let sh = "echo \"$a b\" 'c d' # rm $x\ncat <<EOF\nrm $y\nEOF\nn=$# x=${#a} y=$((1<<3))\nrm $z\n"
        let m = try #require(CodeMask.make(sh as NSString, language: "shell"))
        let code = m.code
        #expect(!code.contains("$a") && !code.contains("rm $x") && !code.contains("rm $y"))
        #expect(code.contains("n=$# x=${#a}") && code.contains("rm $z"))
        // <<- strips tabs before the closing word; quoted words work.
        let dash = "cat <<-'END'\n\trm $q\n\tEND\nrm $w\n"
        let dm = try #require(CodeMask.make(dash as NSString, language: "shell"))
        #expect(!dm.code.contains("$q") && dm.code.contains("rm $w"))
    }

    @Test func windowsThatStartInsideACommentOrDocstring() throws {
        // The window starts part-way into a docstring: its prose isn't code.
        let py = "    'expand_tabs' is false.\n    \"\"\"\n    if x == None:\n        pass\n"
        let m = try #require(CodeMask.make(py as NSString, language: "python", window: true))
        #expect(!m.code.contains("is false") && m.code.contains("if x == None"))
        // An opening docstring after a `def` line, or after `=`, is an opener.
        #expect(CodeMask.startsInside("def f():\n    \"\"\"\n    Doc.\n    \"\"\"\n" as NSString, language: "python") == nil)
        #expect(CodeMask.startsInside("x = \"\"\"\ntext\n\"\"\"\n" as NSString, language: "python") == nil)
        #expect(CodeMask.startsInside("y = 1\ndef f(a):\n    # type: (str) -> None\n    \"\"\"\n    Doc 'a' is it.\n    \"\"\"\n" as NSString, language: "python") == nil)
        #expect(CodeMask.startsInside("s = '''a''' if x else b\n" as NSString, language: "python") == nil)
        // C-like: a `*/` before any `/*`.
        let js = " * debugger; in prose\n */\nfunction f() { debugger; }\n"
        let jm = try #require(CodeMask.make(js as NSString, language: "javascript", window: true))
        #expect(!jm.code.contains("debugger; in prose") && jm.code.contains("{ debugger; }"))
        #expect(CodeMask.startsInside("/* a */ b */" as NSString, language: "javascript") == nil)
        #expect(CodeMask.startsInside("  'mid' is a synonym.\n\"\"\" % params\n" as NSString, language: "python") != nil)
        // The same window through the rules: the hint comes from the code part only.
        let win = OwlContext(fileName: "a.py", language: "python", text: py, textStart: 500, visibleRange: NSRange(location: 0, length: 0),
                             selection: nil, documentID: UUID(), editGeneration: 0, isWholeDocument: false)
        let ids = Self.rules.check(win, facts: OwlDocumentFacts(isWholeDocument: false)).map(\.id)
        #expect(ids.contains(PythonRules.noneCompareID) && !ids.contains(PythonRules.isLiteralID))
        // A window wholly inside a long docstring: no quotes to go by, but prose isn't code.
        let inside = "    widths : float\n        The default is 0.5, or ``0.15*(distance``.\n        Use 'a' is fine.\n"
        let insideWin = OwlContext(fileName: "a.py", language: "python", text: inside, textStart: 9000, visibleRange: NSRange(location: 0, length: 0),
                                   selection: nil, documentID: UUID(), editGeneration: 0, isWholeDocument: false)
        #expect(Self.rules.check(insideWin, facts: OwlDocumentFacts(isWholeDocument: false)).allSatisfy { !$0.id.hasPrefix("rules.py.") })
    }

    @Test func shellWindowsThatStartInsideAHeredoc() throws {
        let sh = "import os\np = os.path.join(a, b)\nPY\nNAME = x\ncat <<EOF\nQ = 1\nEOF\n"
        let m = try #require(CodeMask.make(sh as NSString, language: "shell", window: true))
        #expect(!m.code.contains("os.path") && m.code.contains("NAME = x") && !m.code.contains("Q = 1"))
        #expect(CodeMask.startsInsideHeredoc("cat <<EOF\nx\nEOF\n" as NSString) == nil)
        #expect(CodeMask.startsInsideHeredoc("fi\ndone\n" as NSString) == nil)
    }

    @Test func minifiedCodeGetsNoLanguageHints() {
        let line = String(repeating: "a=1;", count: 600) + "debugger;if(x===NaN){}\n"
        #expect(Self.languageIDs(line, language: "javascript", fileName: "a.min.js").isEmpty)
    }

    // MARK: The table

    @Test func tableIsOrderedAndIDsAreUnique() {
        let ids = RulesHintProvider.languageRules.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("rules.") })
        // The downloaded-script offer, then data loss first, tidy last, style after.
        let correctness = RulesHintProvider.languageRules.filter { $0.tier == .correctness }.map(\.id)
        #expect(ids.first == SafetyRules.downloadedScriptID && ids[1] == ShellRules.cdID && correctness.last == ShellRules.shebangID)
        // Style rules come after every correctness rule (and are off by default).
        let firstStyle = try! #require(RulesHintProvider.languageRules.firstIndex { $0.tier == .style })
        #expect(RulesHintProvider.languageRules[firstStyle...].allSatisfy { $0.tier == .style })
        #expect(Set(RulesHintProvider.languageRules.filter { $0.tier == .style }.map(\.id))
                == [PythonRules.bareExceptID, PythonRules.boolCompareID, ShellRules.backticksID, MarkdownRules.imageAltID])
    }

    @Test func styleRulesNeedTheSettingAndWholeDocumentRulesTheWholeFile() {
        let style = LintRule("rules.test.style", tier: .style, applies: LintRule.languages(["python"])) { _ in
            LintFinding(kind: .tip, title: "style")
        }
        let whole = LintRule("rules.test.whole", wholeDocument: true, applies: LintRule.languages(["python"])) { _ in
            LintFinding(kind: .tip, title: "whole")
        }
        func run(_ facts: OwlDocumentFacts, language: String = "python") -> [String] {
            let ctx = OwlContext(fileName: "a.py", language: language, text: "x = 1\n", textStart: 0, visibleRange: NSRange(location: 0, length: 0),
                                 selection: nil, documentID: UUID(), editGeneration: 0)
            var out: [String] = []
            Self.rules.languageHints(ctx, facts: facts, text: "x = 1\n", lines: [NSRange(location: 0, length: 5)], rules: [style, whole]) { id, _, _, _, _, _ in out.append(id) }
            return out
        }
        #expect(run(OwlDocumentFacts()) == ["rules.test.whole"])
        #expect(run(OwlDocumentFacts(styleTips: true)) == ["rules.test.style", "rules.test.whole"])
        #expect(run(OwlDocumentFacts(isWholeDocument: false, styleTips: true)) == ["rules.test.style"])
        #expect(run(OwlDocumentFacts(styleTips: true), language: "swift").isEmpty)
    }

    @Test func rulesRunOnlyForTheirLanguage() {
        // The same text in another language gets none of them.
        let sh = "FOO = bar\nif [$a = b ]; then echo; fi\n"
        #expect(!Self.languageIDs(sh, language: "shell", fileName: "a.sh").isEmpty)
        #expect(Self.languageIDs(sh, language: "python", fileName: "a.py").isEmpty)
        #expect(Self.languageIDs(sh, language: "plain").isEmpty)
        let py = "if x == None:\n    pass\n"
        #expect(!Self.languageIDs(py, language: "python").isEmpty)
        #expect(Self.languageIDs(py, language: "javascript").isEmpty)
        // .env and TOML rules need their file names: INI files allow both.
        #expect(!Self.languageIDs("A = b\n", language: "ini", fileName: ".env").isEmpty)
        #expect(Self.languageIDs("A = b\n", language: "ini", fileName: "setup.cfg").isEmpty)
    }

    @Test func titlesFitTheBubble() {
        let samples: [(String, String, String)] = [
            ("cd build\nrm -rf *\nNAME = x\necho $NAME\nif [$a = b]; then rm -rf $DIR/out; fi\necho “hi” –la\n", "shell", "a.sh"),
            ("print \"x\"\ndef f(a=[]): pass\nif x == None or y is \"a\": re.compile(\"\\d\")\n", "python", "a.py"),
            ("debugger;\nif (x === NaN || typeof y === \"undefnied\") {}\n", "javascript", "a.js"),
            ("python-version: 3.10\na: 1\na: 2\n", "yaml", "ci.yml"),
            ("<a><b></a>", "xml", "a.xml"),
            ("[a]\nx = word\n[a]\n", "ini", "a.toml"),
            ("A = 1\nA=2\n", "ini", ".env"),
            ("# Install\n\n[x](#instal) [y](#nowhere-near-this-one)\n\n```\nopen\n", "markdown", "a.md"),
            ("a,b,c\n1,2,3\n4,5,6\n7,8,9,10\n1,2,3\n", "csv", "a.csv"),
            ("a,b\n\"x,1\n", "csv", "b.csv"),
            ("SELECT * FROM t WHERE a = NULL;\nDELETE FROM t;\nUPDATE t SET a = 1;\n", "sql", "a.sql"),
            ("if ($a > 5) {}\nGet-Item ` \n", "powershell", "a.ps1"),
        ]
        for (text, lang, name) in samples {
            let hints = Self.check(text, language: lang, fileName: name)
            #expect(!hints.isEmpty, "\(lang)")
            for h in hints { #expect(h.title.count <= 60, "\(h.title)") }
        }
    }

    // MARK: Speed

    /// The worst 8 KB window per language: every rule for it, dense input.
    static func worstCase(_ language: String) -> (String, String) {
        func fill(_ s: String) -> String { String(String(repeating: s, count: 600).utf16.prefix(OwlContextWindow.byteCap))! }
        switch language {
        case "shell": return (fill("cd \"$d\"; rm -rf $x/* \"$y\" # c\nFOO = $(echo \"a\") && [ \"$a\" = b ]\ncat <<EOF\n$z\nEOF\n"), "a.sh")
        case "python": return (fill("def f(a=[], b={}):\n    print \"x\\d\" if a == None else re.match(r'\\w', b) is 'a'\n"), "a.py")
        case "javascript": return (fill("if (x === NaN || typeof y === \"strin\") { debugger; } // \"z\" `${t}` /re/g\n"), "a.js")
        case "yaml": return (fill("a:\n  python-version: [3.8, 3.10]\n  b: |\n    text: 1\n  - c: 2\n    c: 3\n"), "ci.yml")
        case "json": return ("{" + (0..<400).map { "\"k\($0)\": [1, {\"a\": \"b\"}]" }.joined(separator: ",") + "}", "a.json")
        case "xml": return ("<r>" + String(repeating: "<item id=\"1\">text &amp; more</item>\n", count: 200) + "</r>", "a.xml")
        case "toml": return (fill("[t]\nkey = \"v\"\nn = 1_000\nd = 1979-05-27\narr = [1,\n 2]\n[[a]]\nx = word\n"), "a.toml")
        // 0.4.0's writing checks too: skipped levels, repeated headings,
        // footnotes, empty links and broken links matched against a
        // 2,000-file listing (`timingFacts`).
        case "markdown": return (fill("# Head `a` [x](#head) ![i](img/a.png)\n\n```sh\ncode [y](z.md)\n```\n<!-- c --> [r]: other.md\n"
                                      + "### Sub[^1] [e]() [](u) [d](docs/gide.md) ![p](imgs/pic12.png)\n## Head\n[^2]: n\n"), "a.md")
        case "csv": return (fill("a,\"b,c\",d\n1,2,3\n"), "a.csv")
        case "sql": return (fill("UPDATE t SET a = NULL WHERE b = NULL AND c <> 'x = NULL' -- d = NULL\n/* e */ DELETE FROM u;\nGO\n"), "a.sql")
        case "powershell": return (fill("if ($a > 5 -and (Get-X 2>$null)) { 'x > 1' } # c > 2\nGet-Item `  \n@'\nhere ` \n'@\n"), "a.ps1")
        default: return (fill("export A=1\nB = 2\n# c\nC=\"x\ny\"\n"), ".env")
        }
    }

    @Test(.offPool) func languageRulesStayUnder5msPerWindow() {
        for lang in ["shell", "python", "javascript", "yaml", "json", "xml", "toml", "env", "markdown", "csv", "sql", "powershell"] {
            let (text, name) = Self.worstCase(lang)
            let language = lang == "toml" || lang == "env" ? "ini" : lang
            let ns = text as NSString
            let ctx = OwlContext(fileName: name, language: language, text: text, textStart: 0, visibleRange: NSRange(location: 0, length: 0),
                                 selection: nil, documentID: UUID(), editGeneration: 0)
            let lines = RulesHintProvider.lines(ns)
            // The best of 7 in this thread's CPU time, scaled by how slow the
            // machine is right now (see `Timing`). Even the best of 7 on the
            // wall clock came out at 63–165 ms on a slow macos-26 runner
            // (run 45258714905), against 1–6 ms on a dev Mac.
            let r = Timing.best(of: 7) {
                Self.rules.languageHints(ctx, facts: Self.timingFacts, text: ns, lines: lines) { _, _, _, _, _, _ in }
            }
            print("owl-rules-timing \(lang) \(r.description)")
            #expect(r.scaled < Self.budget, "\(lang): \(r.description) per window")
            #expect(r.wall < Self.wallGuard, "\(lang): \(r.description) per window")
        }
    }

    /// Every fact a rule may use is there (a probe that knows its answers,
    /// as the app's cache does after the first query).
    static let timingFacts = OwlDocumentFacts(styleTips: true, fileExists: OwlFileProbe(exists: { _ in false }, files: { timingFiles }))

    /// A folder listing as large as the app's scan makes (2,000 entries).
    static let timingFiles: [String] = (0..<1000).map { "docs/section\($0)/page\($0).md" } + (0..<1000).map { "img/pic\($0).png" }

    /// 5 ms in an optimised build (the plan's budget; `Scripts/test.sh -c
    /// release -Xswiftc -enable-testing` checks it). A debug build runs
    /// 4–10 times slower, and other tests run alongside: the old 50 ms
    /// window budget (`rulesStayFastOnAFullWindow`) there.
    static var budget: TimeInterval {
        #if DEBUG
        return 0.05
        #else
        return 0.005
        #endif
    }

    /// The wall clock's bound, against a blow-up only: 40 times the budget.
    static var wallGuard: TimeInterval { 40 * budget }

    // MARK: Clean corpus

    static var corpusRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/owl-corpus")
    }

    static func language(for url: URL) -> String {
        let name = url.lastPathComponent
        if name.hasPrefix(".env") || name.hasSuffix(".env") { return "ini" }
        return LanguageDetector.language(forFileName: name)?.rawValue ?? "plain"
    }

    /// A real file probe for a file's folder (Markdown's relative links).
    static func probe(for url: URL) -> OwlFileProbe? {
        let folder = url.deletingLastPathComponent()
        guard OwlFileProbe.probes(folder: folder) else { return nil }
        return OwlFileProbe { rel in FileManager.default.fileExists(atPath: folder.appendingPathComponent(rel).path) }
    }

    @Test(.offPool) func cleanCorpusGetsNoLanguageHints() throws {
        let files = try #require(FileManager.default.enumerator(at: Self.corpusRoot, includingPropertiesForKeys: nil)?.allObjects as? [URL])
            .filter { !$0.hasDirectoryPath && $0.lastPathComponent != "LICENSES.md" }
        #expect(files.count >= 12)
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            let lang = Self.language(for: url)
            let ids = Set(RulesHintProvider.languageRules.map(\.id) + [RulesHintProvider.secretID])
            // Every window the owl could be handed, a few KB apart.
            let length = (text as NSString).length
            for at in stride(from: 0, to: max(length, 1), by: 3000) {
                let window = OwlContextWindow(text: text as NSString, visible: NSRange(location: at, length: 0), selection: nil,
                                              fileName: url.lastPathComponent, language: lang, documentID: UUID(), editGeneration: 0)
                // No file probe: a copied Markdown file's relative links point
                // into its own repository (the large run checks them in place).
                let facts = OwlDocumentFacts(isWholeDocument: window.isWholeDocument, styleTips: true)
                let hits = Self.rules.check(window.context, facts: facts).filter { ids.contains($0.id) }
                #expect(hits.isEmpty, "\(url.lastPathComponent) @\(at): \(hits.map { "\($0.id): \($0.title)" })")
            }
        }
    }
}

/// The false-positive gate's larger run (Scripts/owl-corpus.sh): the
/// language rules over a real tree outside the repo, every window the owl
/// could be handed, hits written to a TSV for a hand-checked sample. Skipped
/// unless CEDRIC_OWL_CORPUS names the tree.
@Suite struct OwlCorpusScan {
    static let root = ProcessInfo.processInfo.environment["CEDRIC_OWL_CORPUS"]
    static let skipDirs: Set<String> = [".git", ".build", "build", "dist", "DerivedData", "Pods", ".venv", "venv", "__pycache__", "vendor", "target"]

    @Test(.offPool, .enabled(if: OwlCorpusScan.root != nil)) func owlCorpusScan() throws {
        let root = URL(fileURLWithPath: Self.root!)
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CEDRIC_OWL_CORPUS_OUT"] ?? NSTemporaryDirectory() + "owl-corpus.tsv")
        let maxPerLanguage = Int(ProcessInfo.processInfo.environment["CEDRIC_OWL_CORPUS_MAX"] ?? "") ?? 4000
        // CEDRIC_OWL_CORPUS_LANGS=markdown,csv: only those (a quicker run).
        let only = ProcessInfo.processInfo.environment["CEDRIC_OWL_CORPUS_LANGS"].map { Set($0.split(separator: ",").map(String.init)) }
        // The language rules, and the secrets (0.3.0 added shapes to it).
        let ids = Set(RulesHintProvider.languageRules.map(\.id) + [RulesHintProvider.secretID])
        let rules = RulesHintProvider()
        var rows: [String] = [], perRule: [String: Int] = [:], linesPerLanguage: [String: Int] = [:], filesPerLanguage: [String: Int] = [:]
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return }
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if Self.skipDirs.contains(name) || name == "owl-corpus" { walker.skipDescendants() }
                continue
            }
            var lang = OwlLanguageRulesTests.language(for: url)
            if lang == "plain", let head = try? String(contentsOf: url, encoding: .utf8).prefix(200),
               let l = LanguageDetector.language(forShebang: head.prefix { $0 != "\n" }) { lang = l.rawValue }
            let key = lang == "ini" ? (RulesHintProvider.isEnvFile(lang, name) ? "env" : RulesHintProvider.isTOMLFile(lang, name) ? "toml" : "") : lang
            guard ["shell", "python", "javascript", "typescript", "yaml", "json", "xml", "env", "toml", "markdown", "csv", "sql", "powershell"].contains(key)
                    || (lang == "html" && url.pathExtension.lowercased() == "svg") else { continue }
            let k = key.isEmpty ? "svg" : key
            if let only, !only.contains(k) { continue }
            guard filesPerLanguage[k, default: 0] < maxPerLanguage,
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            filesPerLanguage[k, default: 0] += 1
            let ns = text as NSString
            linesPerLanguage[k, default: 0] += text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            var seen: Set<String> = []
            for at in stride(from: 0, to: max(ns.length, 1), by: 6000) {
                let w = OwlContextWindow(text: ns, visible: NSRange(location: at, length: 0), selection: nil, fileName: name, language: lang,
                                         documentID: UUID(), editGeneration: 0)
                let facts = OwlDocumentFacts(isWholeDocument: w.isWholeDocument, styleTips: true, fileExists: OwlLanguageRulesTests.probe(for: url))
                for h in rules.check(w.context, facts: facts) where ids.contains(h.id) {
                    let loc = w.offset + (h.range?.location ?? 0)
                    guard seen.insert("\(h.id)@\(loc)").inserted else { continue }
                    perRule[h.id, default: 0] += 1
                    let line = RulesHintProvider.lineNumber(ns, at: loc)
                    let lr = ns.lineRange(for: NSRange(location: min(loc, max(0, ns.length - 1)), length: 0))
                    let snippet = ns.substring(with: lr).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\t", with: " ")
                    let title = h.id == RulesHintProvider.secretID ? h.title + " [" + (h.detail ?? "").prefix(60) + "]" : h.title
                    rows.append([h.id, url.path, "\(line)", title, String(snippet.prefix(160))].joined(separator: "\t"))
                }
            }
        }
        var summary = ["# files: \(filesPerLanguage)", "# lines: \(linesPerLanguage)", "# hits: \(perRule)"]
        summary.append(contentsOf: rows)
        try summary.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        print("owl-corpus: \(rows.count) hits, files \(filesPerLanguage), written to \(out.path)")
    }
}
