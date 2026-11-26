import Foundation
import Testing
@testable import CedricCore

/// A clock the tests move by hand.
@MainActor
final class FakeClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

/// Returns fixed hints and counts how often it was asked.
final class StubProvider: OwlHintProvider, @unchecked Sendable {
    let name: String
    var hints: [OwlHint]
    var asked = 0
    init(_ name: String, _ hints: [OwlHint]) { self.name = name; self.hints = hints }
    func hints(for context: OwlContext) async -> [OwlHint] { asked += 1; return hints }
}

func hint(_ id: String, range: NSRange? = nil, replacement: String? = nil) -> OwlHint {
    OwlHint(id: id, kind: .tip, title: id, range: range, replacement: replacement, source: "test")
}

func window(_ text: String, doc: UUID = UUID(), generation: Int = 0, language: String = "plain") -> OwlContextWindow {
    OwlContextWindow(text: text as NSString, visible: NSRange(location: 0, length: 0), selection: nil, fileName: nil,
                     language: language, documentID: doc, editGeneration: generation)
}

func context(_ text: String, language: String = "plain") -> OwlContext { window(text, language: language).context }

@MainActor
@Suite final class OwlCoordinatorTests {
    let clock = FakeClock()
    let suiteName = TestDefaults.name("cedric-owl-test-")
    var defaults: UserDefaults { TestDefaults.defaults(suiteName) }

    deinit { TestDefaults.remove(suiteName) }

    func make(_ hints: [OwlHint]) -> (OwlCoordinator, StubProvider) {
        let reg = OwlProviderRegistry()
        let p = StubProvider("stub", hints)
        reg.register(p)
        let c = OwlCoordinator(registry: reg, defaults: defaults, clock: { [clock] in clock.now })
        return (c, p)
    }

    func current(_ w: OwlContextWindow) -> () -> (length: Int, generation: Int) {
        { ((w.context.text as NSString).length, w.context.editGeneration) }
    }

    @Test func waitsForTypingPauseAndThrottles() async {
        let (c, p) = make([hint("a"), hint("b"), hint("c")])
        let w = window("text")
        #expect(c.nextDueDate == nil)               // nothing happened yet
        c.noteActivity()
        #expect(!c.isDue)
        clock.advance(2.9)
        #expect(await c.queryIfDue(w, facts: .init(), current: current(w)) == nil)
        #expect(p.asked == 0)
        clock.advance(0.2)                          // 3 s pause reached
        #expect(await c.queryIfDue(w, facts: .init(), current: current(w))?.id == "a")
        #expect(p.asked == 1)
        // More typing right away: not asked again for 30 s.
        clock.advance(1); c.noteActivity()
        clock.advance(5)
        #expect(!c.isDue)
        #expect(c.nextDueDate == clock.now.addingTimeInterval(30 - 6))
        clock.advance(24)
        #expect(c.isDue)
        #expect(await c.queryIfDue(w, facts: .init(), current: current(w))?.id == "b")
        // Typing keeps pushing the pause out.
        clock.advance(40); c.noteActivity()
        clock.advance(2); c.noteActivity()
        clock.advance(2)
        #expect(!c.isDue)
        clock.advance(1)
        #expect(c.isDue)
        #expect(p.asked == 2)
    }

    @Test func eachHintShownOncePerDocument() async {
        let (c, _) = make([hint("a")])
        let doc = UUID()
        let w = window("x", doc: doc)
        c.noteActivity(); clock.advance(3)
        #expect(await c.queryIfDue(w, facts: .init(), current: current(w))?.id == "a")
        c.noteActivity(); clock.advance(31)
        #expect(await c.queryIfDue(w, facts: .init(), current: current(w)) == nil)
        // Another document gets it once too.
        let w2 = window("x")
        c.noteActivity(); clock.advance(31)
        #expect(await c.queryIfDue(w2, facts: .init(), current: current(w2))?.id == "a")
        #expect(c.recent.count == 2)
    }

    @Test func snoozeThenComesBack() async {
        let (c, _) = make([hint("a")])
        let w = window("x")
        c.noteActivity(); clock.advance(3)
        #expect(await c.queryIfDue(w, facts: .init(), current: current(w))?.id == "a")
        c.snooze("a")
        c.noteActivity(); clock.advance(60)
        #expect(await c.queryIfDue(w, facts: .init(), current: current(w)) == nil)
        clock.advance(3600)
        c.noteActivity(); clock.advance(3)
        #expect(await c.queryIfDue(w, facts: .init(), current: current(w))?.id == "a")
    }

    @Test func dontShowAgainIsSaved() async {
        let (c, _) = make([hint("a"), hint("b")])
        c.neverShowAgain("a")
        let w = window("x")
        c.noteActivity(); clock.advance(3)
        #expect(await c.queryIfDue(w, facts: .init(), current: current(w))?.id == "b")
        // A new coordinator (next launch) still remembers.
        let again = OwlCoordinator(registry: OwlProviderRegistry(), defaults: defaults, clock: { [clock] in clock.now })
        #expect(again.never.contains("a"))
        again.resetNeverShown()
        #expect(OwlCoordinator(registry: OwlProviderRegistry(), defaults: defaults).never.isEmpty)
    }

    @Test func quietHourBlocksQueries() async {
        let (c, p) = make([hint("a")])
        let w = window("x")
        c.quiet(for: 3600)
        c.noteActivity(); clock.advance(100)
        #expect(!c.isDue)
        #expect(await c.queryIfDue(w, facts: .init(), current: current(w)) == nil)
        #expect(p.asked == 0)
        clock.advance(3500)
        #expect(c.isDue)
        #expect(await c.queryIfDue(w, facts: .init(), current: current(w))?.id == "a")
    }

    @Test func letterIsShownOnceEver() async {
        let (c, _) = make([hint(RulesHintProvider.letterID)])
        let w = window("x")
        c.noteActivity(); clock.advance(3)
        #expect(await c.queryIfDue(w, facts: .init(), current: current(w))?.id == RulesHintProvider.letterID)
        #expect(c.never.contains(RulesHintProvider.letterID))
        let w2 = window("x")
        c.noteActivity(); clock.advance(31)
        #expect(await c.queryIfDue(w2, facts: .init(), current: current(w2)) == nil)
    }

    @Test func hintRangesAreMovedByTextStartAndCheckedAgainstTheDocument() async {
        // A 20,000-character document: the context is a window into it.
        var lines: [String] = []
        for i in 0..<1000 { lines.append(String(format: "line %05d ......", i)) }
        let full = lines.joined(separator: "\n") as NSString
        let visible = NSRange(location: full.length / 2, length: 100)
        let w = OwlContextWindow(text: full, visible: visible, selection: nil, fileName: nil, language: "plain",
                                 documentID: UUID(), editGeneration: 7)
        #expect(!w.isWholeDocument)
        #expect(w.context.textStart == w.offset && w.offset > 0)
        #expect((w.context.text as NSString).length <= OwlContextWindow.byteCap)
        #expect(full.substring(with: NSRange(location: w.offset, length: (w.context.text as NSString).length)) == w.context.text)
        #expect(w.context.visibleRange.location == visible.location - w.offset)

        let h = hint("r", range: NSRange(location: 6, length: 5))
        #expect(OwlCoordinator.documentRange(h, context: w.context) == NSRange(location: w.offset + 6, length: 5))
        #expect(OwlCoordinator.matchesDocument(h, context: w.context, length: full.length, generation: 7))
        // Edited since: dropped. Out of the document: dropped. No range: kept.
        #expect(!OwlCoordinator.matchesDocument(h, context: w.context, length: full.length, generation: 8))
        #expect(!OwlCoordinator.matchesDocument(h, context: w.context, length: w.offset + 3, generation: 7))
        #expect(!OwlCoordinator.matchesDocument(hint("r", range: NSRange(location: 0, length: 9_000)), context: w.context, length: full.length, generation: 7))
        #expect(OwlCoordinator.matchesDocument(hint("n"), context: w.context, length: 0, generation: 99))

        let (c, _) = make([h, hint("plain")])
        c.noteActivity(); clock.advance(3)
        let shown = await c.queryIfDue(w, facts: .init(), current: { (full.length, 8) })  // typed meanwhile
        #expect(shown?.id == "plain")
    }

    @Test func registryGatesTheAISource() async {
        let reg = OwlProviderRegistry()
        reg.register(RulesHintProvider())
        var changes = 0
        reg.onChange = { changes += 1 }
        #expect(!reg.hasAIProvider)
        #expect(reg.providers(for: .rulesAndAI).count == 1)
        reg.register(StubProvider("local:test", []), isAI: true)
        #expect(reg.hasAIProvider && changes == 1)
        #expect(reg.providers(for: .rules).map(\.name) == ["rules"])
        #expect(reg.providers(for: .rulesAndAI).map(\.name) == ["rules", "local:test"])
        reg.unregister(name: "local:test")
        #expect(!reg.hasAIProvider)
    }

    /// Settings selects Rules + AI only when the AI goes from off to on.
    /// An interval or model change while it is already on leaves Rules.
    @Test func rulesPlusAIOnlyWhenTheAITurnsOn() {
        #expect(OwlHintSource.rules.afterAIApply(wasActive: false, isActive: true) == .rulesAndAI)
        #expect(OwlHintSource.rules.afterAIApply(wasActive: true, isActive: true) == .rules)
        #expect(OwlHintSource.rulesAndAI.afterAIApply(wasActive: true, isActive: true) == .rulesAndAI)
        #expect(OwlHintSource.rules.afterAIApply(wasActive: false, isActive: false) == .rules)
        #expect(OwlHintSource.rulesAndAI.afterAIApply(wasActive: true, isActive: false) == .rulesAndAI)
    }
}

@Suite struct OwlRulesTests {
    let rules = RulesHintProvider()

    func ids(_ text: String, language: String = "plain", facts: OwlDocumentFacts = OwlDocumentFacts()) -> [String] {
        rules.check(context(text, language: language), facts: facts).map(\.id)
    }

    func apply(_ h: OwlHint, to text: String) -> String {
        (text as NSString).replacingCharacters(in: h.range!, with: h.replacement!)
    }

    @Test func oneLineJSONIsFormattedKeepingKeyOrder() throws {
        let text = #"{"z":1,"a":[1,2,{"b":"x, y: {z}"}],"e":{},"l":[],"s":"q\"uote"}"# + "\n"
        let h = try #require(rules.check(context(text, language: "json"), facts: .init()).first { $0.id == RulesHintProvider.jsonID })
        #expect(h.title == "Looks like JSON. Format it?")
        let out = apply(h, to: text)
        #expect(out == """
        {
          "z": 1,
          "a": [
            1,
            2,
            {
              "b": "x, y: {z}"
            }
          ],
          "e": {},
          "l": [],
          "s": "q\\"uote"
        }

        """)
        // Same value after formatting.
        let a = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? NSDictionary
        #expect(a == b)
    }

    @Test func jsonRuleSkipsFormattedInvalidAndPartialText() {
        #expect(!ids("{\n  \"a\": 1\n}\n").contains(RulesHintProvider.jsonID))
        #expect(!ids("{\"a\": 1,}").contains(RulesHintProvider.jsonID))
        #expect(!ids("{}").contains(RulesHintProvider.jsonID))
        #expect(!ids("\"just a string\"").contains(RulesHintProvider.jsonID))
        #expect(!ids("{\"a\":1}", facts: .init(isWholeDocument: false)).contains(RulesHintProvider.jsonID))
    }

    @Test func mixedIndentConvertsTabsToSpaces() throws {
        let text = "func a() {\n\tlet x = 1\n    let y = 2\n    let z = 3\n\t\treturn\n}\n"
        let h = try #require(rules.check(context(text), facts: .init()).first { $0.id == RulesHintProvider.mixedIndentID })
        #expect(h.title == "Mixed tabs and spaces. Convert to spaces?")
        #expect(apply(h, to: text) == "func a() {\n    let x = 1\n    let y = 2\n    let z = 3\n        return\n}\n")
        #expect(!ids("a\n\tb\n\tc\n").contains(RulesHintProvider.mixedIndentID))
        #expect(!ids("a\n    b\n  c\n").contains(RulesHintProvider.mixedIndentID))
    }

    @Test func trailingWhitespaceOnManyLines() throws {
        let text = "a  \nb\t\nc \nd   \ne \nf\n   \n"
        let h = try #require(rules.check(context(text), facts: .init()).first { $0.id == RulesHintProvider.trailingID })
        #expect(h.title == "5 lines end in spaces. Trim?")
        #expect(apply(h, to: text) == "a\nb\nc\nd\ne\nf\n   \n")
        #expect(!ids("a \nb \nc \nd \n").contains(RulesHintProvider.trailingID))      // only 4
        #expect(!ids(text, language: "markdown").contains(RulesHintProvider.trailingID)) // hard breaks
    }

    @Test func documentFactRules() {
        let base = Date(timeIntervalSince1970: 5_000_000)
        let r = RulesHintProvider(now: { base })
        func ids(_ f: OwlDocumentFacts) -> [String] { r.check(context("hello"), facts: f).map(\.id) }
        #expect(ids(.init()).isEmpty)
        #expect(ids(.init(changedOnDisk: true)) == [RulesHintProvider.reloadID])
        #expect(ids(.init(unsavedSince: base.addingTimeInterval(-7300))) == [RulesHintProvider.saveCopyID])
        #expect(ids(.init(unsavedSince: base.addingTimeInterval(-3600))).isEmpty)
        #expect(ids(.init(lineEnding: .crlf)) == [RulesHintProvider.crlfID])
        let crlf = r.check(context("x"), facts: .init(lineEnding: .crlf))[0]
        #expect(crlf.replacement == nil && crlf.kind == .explain)
    }

    @Test func letterEasterEgg() throws {
        #expect(RulesHintProvider.isLetter("Dear Sir,\n\nI write\nto say\n\nYours faithfully,\nAl\n"))
        #expect(!RulesHintProvider.isLetter("Dear Sir,\nhi\nbye\n"))          // no sign-off
        #expect(!RulesHintProvider.isLetter("dear Sir,\n\n\n\nRegards\n"))
        #expect(!RulesHintProvider.isLetter("Hello\nDear x\n\n\n"))
        let h = try #require(rules.check(context("Dear Owl,\nhello\nthere\nLove,\nbye"), facts: .init()).first)
        #expect(h.id == RulesHintProvider.letterID)
        #expect(h.title == "It looks like you’re writing a letter. Would you like help?")
        #expect(h.title.count <= 60)
    }

    @Test func titlesFitTheBubble() {
        let r = RulesHintProvider(now: { Date.distantFuture })
        let text = "{\"a\":[1]}\n\tx\n  y\n" + String(repeating: "z \n", count: 6)
        let all = r.check(context(text), facts: .init(changedOnDisk: true, unsavedSince: .distantPast, lineEnding: .crlf))
        #expect(all.count >= 5)
        for h in all { #expect(h.title.count <= 60, "\(h.title)") }
    }

    @Test func minimalEditKeepsCommonEnds() {
        let s = "abc  \ndef  \n" as NSString
        let e = OwlEdit.minimal(in: s, range: NSRange(location: 0, length: s.length), replacement: "abc\ndef\n")
        #expect(e.range == NSRange(location: 3, length: 8))
        #expect(e.replacement == "\ndef")
        #expect(s.replacingCharacters(in: e.range, with: e.replacement) == "abc\ndef\n")
    }
}

/// Hints that arrive on their own (the AI scheduler's) go through the
/// same checks as a query's.
@MainActor
@Suite struct OwlAcceptTests {
    struct Marker: OwlHintProvider { let name = "local:m"; func hints(for context: OwlContext) async -> [OwlHint] { [] } }

    @Test func acceptAIOnlyWithRulesAndAIAndChecksRanges() {
        let (d, suite) = TestDefaults.make("cedric-accept-")
        defer { TestDefaults.remove(suite) }
        let c = OwlCoordinator(defaults: d)
        let doc = UUID()
        let ctx = OwlContext(fileName: "a.swift", language: "swift", text: "for i in 0...n {}", textStart: 400,
                             visibleRange: NSRange(location: 0, length: 5), selection: nil, documentID: doc, editGeneration: 7)
        let h = OwlHint(id: "ai1", kind: .fix, title: "Off by one", range: NSRange(location: 9, length: 4),
                        replacement: "0..<n", source: "local:m")
        // No AI provider registered / source Rules: dropped.
        #expect(c.acceptAI([h], context: ctx, length: 1000, generation: 7) == nil)
        c.registry.register(Marker(), isAI: true)
        #expect(c.acceptAI([h], context: ctx, length: 1000, generation: 7) == nil)
        c.source = .rulesAndAI
        // Edited since, or out of the document: dropped.
        #expect(c.acceptAI([h], context: ctx, length: 1000, generation: 8) == nil)
        #expect(c.acceptAI([h], context: ctx, length: 410, generation: 7) == nil)
        #expect(c.acceptAI([h], context: ctx, length: 1000, generation: 7) == h)
        #expect(OwlCoordinator.documentRange(h, context: ctx) == NSRange(location: 409, length: 4))
        // Shown once per document.
        #expect(c.acceptAI([h], context: ctx, length: 1000, generation: 7) == nil)
        #expect(c.recent.first?.hint.source == "local:m")
    }
}
