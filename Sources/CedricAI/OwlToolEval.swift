import Foundation
import CedricCore

/// The fixed tool-prompt set behind model gating (Scripts/owl-tools-eval.sh):
/// 58 questions over seven sample documents (Markdown, Swift, JSON, CSV,
/// prose, HTML, and an SVG icon). The model sees only lines 1–12 (as in
/// the panel's "Visible text"), offered the tools the panel offers for
/// that question (`OwlTools.typedTools`: a few, picked by the question)
/// and describe_image too (a text document must leave it alone), and must either pick the
/// expected tool with usable arguments or answer directly when no tool is
/// needed. Scores ≥ `OwlToolGate.threshold` (0.8) turn tools on for that
/// model; the results go to Resources/AI/owl-tool-scores.json.
public enum OwlToolEval {
    public struct Case: Sendable {
        public var doc: String
        public var question: String
        /// Acceptable first tools; empty: the right move is to answer.
        public var expect: Set<OwlToolName>
        /// An argument that must be right ("start" line, "query" text).
        public var arg: (key: String, value: String)?
        public var selection: NSRange?
    }

    public struct Result: Sendable {
        public var question: String
        public var expected: String
        public var got: String
        public var pass: Bool
        /// Wall time of the case (every model turn and tool run), seconds.
        public var seconds: TimeInterval = 0
    }

    public static let shown = 12

    // MARK: The documents

    public static let docs: [String: (language: String, file: String, text: String)] = {
        var d: [String: (String, String, String)] = [:]
        var md = "# Garden notes\n\nNotes on the vegetable garden for this year.\n\n## Planting\n\nTomatoes go in after the last frost.\nBeans follow two weeks later.\n\n"
        for i in 1...8 { md += "- Bed \(i): water every \(i % 3 + 1) days\n" }
        md += "\n## Pests\n\nSlugs ate the lettuce in May. Copper tape helped.\n\n## Harvest\n\n"
        for i in 1...10 { md += "Week \(i): picked \(i * 2) kg of tomatoes.\n" }
        md += "\n## Budget\n\nSeeds cost 40 euros. Compost cost 25 euros.\n"
        d["md"] = ("markdown", "garden.md", md)
        var sw = "import Foundation\n\nstruct Config {\n    var name: String\n    var retries: Int\n}\n\n"
        sw += "func parseConfig(_ text: String) -> Config? {\n    let parts = text.split(separator: \"=\")\n    guard parts.count == 2 else { return nil }\n    return Config(name: String(parts[0]), retries: Int(parts[1]) ?? 0)\n}\n\n"
        for i in 1...10 { sw += "func helper\(i)(_ x: Int) -> Int {\n    return x * \(i)\n}\n\n" }
        sw += "func main() {\n    let c = parseConfig(\"server=3\")\n    print(c?.retries ?? 0)\n    let d = parseConfig(\"bad\")\n    print(d == nil)\n}\n"
        d["swift"] = ("swift", "Config.swift", sw)
        var js = "{\n  \"name\": \"cedric\",\n  \"version\": \"0.1.0\",\n  \"settings\": {\n    \"theme\": \"dark\",\n    \"fontSize\": 13\n  },\n  \"plugins\": [\n"
        for i in 1...20 { js += "    {\"id\": \"plugin\(i)\", \"enabled\": \(i % 2 == 0)}\(i < 20 ? "," : "")\n" }
        js += "  ],\n  \"timeoutSeconds\": 30,\n  \"license\": \"MIT\"\n}\n"
        d["json"] = ("json", "settings.json", js)
        var csv = "date,city,temperature,rain_mm\n"
        let cities = ["Oslo", "Lisbon", "Berlin", "Rome"]
        for i in 1...40 { csv += "2026-03-\(String(format: "%02d", (i % 28) + 1)),\(cities[i % 4]),\(5 + i % 17),\(i % 7)\n" }
        d["csv"] = ("csv", "weather.csv", csv)
        var prose = "Dear Ms. Lane,\n\nThank you for your letter about the library opening hours.\n"
        let sentences = ["The library will open at nine on weekdays.", "On Saturdays it opens at ten.", "The reading room closes an hour earlier.",
                         "Children's events are held on Wednesday afternoons.", "We are sorry for the confusion in the newsletter.",
                         "The new catalogue goes online in April.", "Parking behind the building is free after six.",
                         "Volunteers are always welcome at the front desk."]
        for i in 0..<30 { prose += sentences[i % sentences.count] + (i % 3 == 2 ? "\n\n" : " ") }
        prose += "\nKind regards,\nPeter Holm\nHead Librarian\n"
        d["prose"] = ("plain", "letter.txt", prose)
        var html = "<!doctype html>\n<html>\n<head>\n  <title>Bakery</title>\n</head>\n<body>\n  <h1>Fresh bread daily</h1>\n  <p>Open from seven.</p>\n"
        for i in 1...12 { html += "  <section>\n    <h2>Loaf \(i)</h2>\n    <p>Price: \(i + 2) euros</p>\n  </section>\n" }
        html += "  <footer>Contact: hello@example.com</footer>\n</body>\n</html>\n"
        d["html"] = ("html", "index.html", html)
        // The binoculars icon from Derek's question (Lucide-style strokes).
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="53" height="53" viewBox="0 0 24 24"
             fill="none" stroke="black" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M10 10h4"/>
          <path d="M19 7V4a1 1 0 0 0-1-1h-2a1 1 0 0 0-1 1v3"/>
          <path d="M20 21a2 2 0 0 0 2-2v-3.851c0-1.39-2-2.962-2-4.829V8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v11a2 2 0 0 0 2 2z"/>
          <path d="M22 16H2"/>
          <path d="M4 21a2 2 0 0 1-2-2v-3.851c0-1.39 2-2.962 2-4.829V8a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v11a2 2 0 0 1-2 2z"/>
          <path d="M9 7V4a1 1 0 0 0-1-1H6a1 1 0 0 0-1 1v3"/>
        </svg>

        """
        d["svg"] = ("html", "binoculars.svg", svg)
        return d
    }()

    // MARK: The questions

    public static let cases: [Case] = {
        func c(_ doc: String, _ q: String, _ e: [OwlToolName], _ arg: (String, String)? = nil, sel: NSRange? = nil) -> Case {
            Case(doc: doc, question: q, expect: Set(e), arg: arg.map { (key: $0.0, value: $0.1) }, selection: sel)
        }
        return [
            // get_lines: lines beyond what is shown.
            c("md", "What does line 30 say?", [.getLines], ("start", "30")),
            c("swift", "Show me lines 40 to 44 and tell me what they do.", [.getLines], ("start", "40")),
            c("json", "What is on line 28?", [.getLines], ("start", "28")),
            c("csv", "Read line 35 and tell me the city.", [.getLines], ("start", "35")),
            c("prose", "What does the last line of the letter say? The letter has about 25 lines; read lines 20 to 25.", [.getLines], ("start", "20")),
            c("html", "What is the price on line 50?", [.getLines], ("start", "50")),
            c("md", "Read lines 25 to 32 and summarise them.", [.getLines], ("start", "25")),
            // search_document.
            c("swift", "Where is parseConfig called? Search the document for 'parseConfig'.", [.searchDocument], ("query", "parseConfig")),
            c("md", "Find every mention of 'Copper' in the notes.", [.searchDocument], ("query", "Copper")),
            c("json", "Search for 'timeoutSeconds' and tell me its value.", [.searchDocument], ("query", "timeoutSeconds")),
            c("csv", "On which lines does 'Lisbon' appear?", [.searchDocument], ("query", "Lisbon")),
            c("prose", "Does the letter mention 'Parking'? Search for it.", [.searchDocument], ("query", "Parking")),
            c("html", "Find the line with 'footer'.", [.searchDocument], ("query", "footer")),
            c("swift", "How many times is 'helper7' used? Search for it.", [.searchDocument], ("query", "helper7")),
            // get_outline.
            c("md", "What are the section headings of this document?", [.getOutline]),
            c("swift", "Give me an outline: which functions are defined in this file?", [.getOutline, .searchDocument]),
            c("md", "List the sections in this file.", [.getOutline]),
            c("html", "What is the structure of this page? Use the outline.", [.getOutline]),
            c("json", "What are the top-level keys? Get the outline.", [.getOutline]),
            // document_stats.
            c("prose", "How many words are in this letter?", [.documentStats]),
            c("md", "How many lines does this document have?", [.documentStats]),
            c("csv", "How long is this file, in lines and characters?", [.documentStats]),
            c("swift", "What is the file name and language of this document?", [.documentStats]),
            // get_selection.
            c("swift", "Explain the code I have selected.", [.getSelection], sel: NSRange(location: 400, length: 60)),
            c("prose", "Is the selected sentence polite enough?", [.getSelection], sel: NSRange(location: 600, length: 50)),
            c("md", "Summarise my selection.", [.getSelection], sel: NSRange(location: 500, length: 80)),
            // propose_edit.
            c("md", "Change line 1 to \"# Garden notes 2026\". Propose the edit.", [.proposeEdit, .getLines], ("start", "1")),
            c("swift", "Rename the struct on line 3 from Config to AppConfig: propose an edit to line 3.", [.proposeEdit, .getLines], ("start", "3")),
            c("json", "Propose an edit that changes line 3 to set the version to \"0.2.0\".", [.proposeEdit, .getLines], ("start", "3")),
            c("prose", "Rewrite line 3 to be more formal and propose it as an edit.", [.proposeEdit, .getLines], ("start", "3")),
            c("html", "Change the title on line 4 to \"Bakery Lane\" with a proposed edit.", [.proposeEdit, .getLines], ("start", "4")),
            c("csv", "Propose changing the header on line 1 to use rain instead of rain_mm.", [.proposeEdit, .getLines], ("start", "1")),
            // propose_edit (0.4.1, find/replace): asked for in other words.
            c("md", "Shorten line 3 to \"Garden notes for this year.\"", [.proposeEdit, .getLines], ("start", "3")),
            c("prose", "Fix line 3: replace \"opening hours\" with \"open hours\".", [.proposeEdit, .getLines], ("start", "3")),
            c("swift", "Please rename the function declared on line 8 from parseConfig to parseSettings, on that line only.", [.proposeEdit, .getLines], ("start", "8")),
            c("json", "Could you update the theme on line 5 from dark to light?", [.proposeEdit, .getLines], ("start", "5")),
            // Not propose_edit: questions about the text, even with an edit word in them.
            c("md", "Is the sentence on line 3 correct English?", []),
            c("swift", "What would you change on line 9 to make it safer? Just tell me.", []),
            c("prose", "Change of plan: what is the greeting on line 1?", []),
            c("json", "Does the version on line 3 need fixing?", []),
            // No tool: the answer is in what is shown, or needs no document.
            c("md", "What is the title on line 1?", []),
            c("swift", "What does line 1 import?", []),
            c("json", "What is the name on line 2?", []),
            c("csv", "What are the column names on line 1?", []),
            c("prose", "Who is the letter addressed to (line 1)?", []),
            c("html", "What is the h1 text on line 7?", []),
            c("md", "In one sentence, what is a raised garden bed? No need to look at the document.", []),
            c("swift", "What does the keyword 'guard' mean in Swift, in general?", []),
            // check_document (0.4.0): the offline checks' findings.
            c("md", "What problems does this document have?", [.checkDocument]),
            c("swift", "Are there any errors or warnings in this file? Run the checks.", [.checkDocument]),
            // read_section (0.4.0): a Markdown section by its heading.
            c("md", "What does the Pests section say?", [.readSection], ("heading", "Pests")),
            c("md", "Read me the Budget section.", [.readSection], ("heading", "Budget")),
            // describe_image: an SVG's picture; never for a text document.
            c("svg", "What is it a picture of?", [.describeImage]),
            c("svg", "What does this image show?", [.describeImage]),
            c("svg", "Describe the icon this file draws.", [.describeImage]),
            c("svg", "What is the stroke width on line 2?", []),
            c("prose", "What is this a picture of?", []),
            c("md", "Is there an image in these notes?", []),
        ]
    }()

    /// One case: the first move the model makes.
    public static func run(_ c: Case, engine: any OwlChatEngine) async -> Result {
        let t0 = Date()
        // Run on purpose (Scripts/owl-tools-eval.sh): may load the built-in model.
        var r = await BuiltInLoad.userAsked { await firstMove(c, engine: engine) }
        r.seconds = Date().timeIntervalSince(t0)
        return r
    }

    private static func firstMove(_ c: Case, engine: any OwlChatEngine) async -> Result {
        let d = docs[c.doc]!
        let snap = snapshot(c)
        let ctx = OwlChatContext.build(snap, scope: .visible, budget: 6000)!
        // The tools the panel offers for this question (`OwlTools.typedTools`),
        // and describe_image for every document: a text one must leave it alone.
        let offered = offeredTools(c.question, snap)
        let toolbox = OwlToolbox(snapshot: snap, allowed: Set(offered))
        let messages = OwlPrompts.chatMessages(question: c.question, context: ctx, language: Language(rawValue: d.language)?.displayName ?? d.language,
                                               fileName: d.file, history: [], toolsOn: true, model: engine.scoreKey,
                                               canDescribeImage: OwlPicture.isPicture(fileName: d.file),
                                               totalLines: snap.lineCount, canEdit: offered.contains(.proposeEdit))
        let expected = c.expect.isEmpty ? "answer" : c.expect.map(\.rawValue).sorted().joined(separator: "|")
        let turn: OwlTurn
        do {
            turn = try await engine.turn(messages, tools: OwlTools.specs(offered), toolbox: toolbox, maxTokens: 300) { _ in }
        } catch {
            return Result(question: c.question, expected: expected, got: "error: \(error)", pass: false)
        }
        // Apple runs its tools itself: its first call is in the toolbox's log.
        let first: OwlToolCall?
        switch turn {
        case .toolCalls(let calls): first = calls.first
        case .answer: first = toolbox.log.first
        }
        guard let call = first else {
            return Result(question: c.question, expected: expected, got: "answer", pass: c.expect.isEmpty)
        }
        var pass = false
        if let name = OwlToolName(rawValue: call.name), c.expect.contains(name) {
            let r = OwlTools.run(call, on: snap)
            // describe_image needs the app's renderer: choosing it is the test.
            // propose_edit must be usable as asked: find occurs once, at the line asked about.
            pass = r.ok || name == .describeImage
            if let arg = c.arg, pass {
                let v = call.arguments[arg.key]
                if name == .proposeEdit, arg.key == "start" {
                    pass = r.proposal.map { ($0.firstLine...$0.lastLine).contains(Int(arg.value)!) } ?? false
                } else if arg.key == "start" {
                    // A range that includes the line counts.
                    let s = v?.int ?? -1, e = call.arguments["end"]?.int ?? s
                    pass = (s...max(s, e)).contains(Int(arg.value)!) || abs(s - Int(arg.value)!) <= 1
                } else if arg.key == "query" || arg.key == "heading" {
                    pass = (v?.string ?? "").lowercased().contains(arg.value.lowercased())
                }
            }
        }
        return Result(question: c.question, expected: expected, got: "\(call.name) \(call.arguments.jsonString)", pass: pass)
    }

    /// The tools a case is offered: the typed-question set plus describe_image.
    public static func offeredTools(_ question: String, _ snap: OwlDocumentSnapshot) -> [OwlToolName] {
        OwlTools.typedTools(question: question, snapshot: snap) + [.describeImage]
    }

    /// The snapshot a case runs on (shown lines 1–`shown`, its selection).
    public static func snapshot(_ c: Case) -> OwlDocumentSnapshot {
        let d = docs[c.doc]!
        let full = d.text as NSString
        let shownRange = OwlDocumentSnapshot(text: d.text, generation: 1).range(lines: 1, shown)!
        return OwlDocumentSnapshot(text: d.text, generation: 1, selection: c.selection.map { NSIntersectionRange($0, NSRange(location: 0, length: full.length)) } ?? NSRange(location: 0, length: 0),
                                   visible: shownRange, fileName: d.file, language: d.language)
    }

    public static func runAll(engine: any OwlChatEngine) async -> (score: Double, results: [Result]) {
        var results: [Result] = []
        for c in cases { results.append(await run(c, engine: engine)) }
        let score = Double(results.filter(\.pass).count) / Double(max(1, results.count))
        return (score, results)
    }

    /// Adds or replaces `key`'s score in the scores JSON.
    public static func record(score: Double, key: String, cases: Int, in url: URL, date: Date = Date()) throws {
        var obj = ((try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        // Three decimals as written (JSONSerialization would print 0.59999999999999998).
        func dec(_ v: Any?) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.3f", (v as? Double) ?? 0.8)) }
        obj["threshold"] = dec(obj["threshold"] ?? 0.8)
        var models = obj["models"] as? [String: Any] ?? [:]
        for (k, v) in models {
            guard var m = v as? [String: Any] else { continue }
            m["score"] = dec(m["score"])
            models[k] = m
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        models[key] = ["score": NSDecimalNumber(string: String(format: "%.3f", score)), "cases": cases, "date": f.string(from: date)]
        obj["models"] = models
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }
}
