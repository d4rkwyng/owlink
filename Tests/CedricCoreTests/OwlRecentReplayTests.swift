import Foundation
import Testing
@testable import CedricCore

/// "Recent hints" in the owl's popover can be shown again: no new query,
/// though the hint is already shown (not eligible); a stale range still
/// gives the stored title and detail.
@MainActor
@Suite final class OwlRecentReplayTests {
    let clock = FakeClock()
    let suiteName = TestDefaults.name("cedric-owl-test-")
    var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    deinit { TestDefaults.remove(suiteName) }

    func make(_ hints: [OwlHint]) -> (OwlCoordinator, StubProvider) {
        let reg = OwlProviderRegistry()
        let p = StubProvider("stub", hints)
        reg.register(p)
        return (OwlCoordinator(registry: reg, defaults: defaults, clock: { [clock] in clock.now }), p)
    }

    func current(_ w: OwlContextWindow) -> () -> (length: Int, generation: Int) {
        { ((w.context.text as NSString).length, w.context.editGeneration) }
    }

    static let text = "Fix the the bug.\n"
    static let doubled = OwlHint(id: "rules.duplicate-word", kind: .fix, title: "“the” twice", detail: "The word “the” is repeated.",
                                 range: NSRange(location: 4, length: 8), replacement: "the ", source: "rules")

    @Test func aShownHintReplaysWithoutBeingEligibleOrAskingAgain() async throws {
        let (c, p) = make([Self.doubled])
        let doc = UUID()
        let w = window(Self.text, doc: doc)
        c.noteActivity(); clock.advance(3)
        #expect(await c.queryIfDue(w, facts: .init(), current: current(w))?.id == Self.doubled.id)
        #expect(p.asked == 1)
        #expect(!c.isEligible(Self.doubled, documentID: doc))
        let shown = try #require(c.recent.first)
        #expect(shown.documentRange == NSRange(location: 4, length: 8))
        #expect(shown.expected == "the the ")
        let r = OwlCoordinator.replay(shown, document: Self.text as NSString)
        #expect(!r.isStale)
        #expect(r.hint == Self.doubled)
        #expect(r.documentRange == NSRange(location: 4, length: 8))
        #expect(r.expected == "the the ")
        // Nothing was asked, nothing re-marked, and it still isn't eligible.
        #expect(p.asked == 1)
        #expect(c.queryCount == 1)
        #expect(c.recent.count == 1)
        #expect(!c.isEligible(Self.doubled, documentID: doc))
    }

    @Test func aStaleRangeStillGivesTitleAndDetail() async throws {
        let (c, _) = make([Self.doubled])
        let w = window(Self.text)
        c.noteActivity(); clock.advance(3)
        _ = await c.queryIfDue(w, facts: .init(), current: current(w))
        let shown = try #require(c.recent.first)
        for now in ["Fix the bug.\n", "Fix", "", "Now: Fix the the bug.\n"] {
            let r = OwlCoordinator.replay(shown, document: now as NSString)
            #expect(r.isStale, "\(now.debugDescription)")
            #expect(r.hint.title == Self.doubled.title)
            #expect(r.hint.detail == Self.doubled.detail)
            #expect(r.hint.id == Self.doubled.id)
            #expect(r.hint.range == nil && r.hint.replacement == nil, "no highlight, no Fix it")
            #expect(r.documentRange == nil && r.expected == nil)
        }
        // The document closed.
        let gone = OwlCoordinator.replay(shown, document: nil)
        #expect(gone.isStale && gone.hint.title == Self.doubled.title && gone.hint.detail == Self.doubled.detail)
    }

    @Test func aRangeInAWindowIsStoredInDocumentCoordinates() throws {
        let (c, _) = make([])
        let doc = UUID()
        // A context window starting at 100 in the document.
        let ctx = OwlContext(fileName: nil, language: "plain", text: Self.text, textStart: 100,
                             visibleRange: NSRange(location: 0, length: 0), selection: nil, documentID: doc, editGeneration: 0)
        c.markShown(Self.doubled, documentID: doc, context: ctx)
        let shown = try #require(c.recent.first)
        #expect(shown.documentRange == NSRange(location: 104, length: 8))
        let document = (String(repeating: "x", count: 100) + Self.text) as NSString
        let r = OwlCoordinator.replay(shown, document: document)
        #expect(!r.isStale && r.documentRange == NSRange(location: 104, length: 8))
        // Without a context (older callers): nothing to check against, so stale.
        c.markShown(hint("other", range: NSRange(location: 0, length: 3)), documentID: doc)
        let bare = try #require(c.recent.first)
        #expect(bare.documentRange == nil)
        #expect(OwlCoordinator.replay(bare, document: document).isStale)
    }

    @Test func aHintWithoutARangeIsNeverStale() throws {
        let (c, _) = make([])
        let doc = UUID()
        let note = OwlHint(id: "rules.reload", kind: .warning, title: "Changed on disk", detail: "Reload it?", source: "rules")
        c.markShown(note, documentID: doc, context: window("abc", doc: doc).context)
        let shown = try #require(c.recent.first)
        let r = OwlCoordinator.replay(shown, document: nil)
        #expect(!r.isStale && r.hint == note && r.documentRange == nil)
    }
    /// A recent "Looks like JSON. Format it?" whose text has changed: replay
    /// strips its range and replacement but keeps the ID, and before 0.5.4
    /// the bubble took that ID without a replacement for the long one-line
    /// file's hint and offered Fix it, formatting the whole current file.
    @Test func aStaleJSONHintIsNotTheWholeFileFormatter() throws {
        let (c, _) = make([])
        let doc = UUID()
        let minified = #"{"a":1,"b":[1,2]}"#
        let inView = OwlHint(id: RulesHintProvider.jsonID, kind: .fix, title: "Looks like JSON. Format it?",
                             range: NSRange(location: 0, length: (minified as NSString).length),
                             replacement: "{\n  \"a\" : 1,\n  \"b\" : [1, 2]\n}", source: "rules")
        c.markShown(inView, documentID: doc, context: window(minified, doc: doc).context)
        let shown = try #require(c.recent.first)
        // Still the same text: its own Fix it (the replacement), not the whole-file one.
        let fresh = OwlCoordinator.replay(shown, document: minified as NSString)
        #expect(!fresh.isStale && fresh.hint.replacement != nil)
        #expect(!RulesHintProvider.formatsWholeJSONFile(fresh.hint, isStale: fresh.isStale))
        // The text changed (or the file closed): stale, and no whole-file format.
        let changed: [NSString?] = [#"{"a":2,"b":[1,2]}"# as NSString, "not json at all" as NSString, "" as NSString, nil]
        for now in changed {
            let r = OwlCoordinator.replay(shown, document: now)
            #expect(r.isStale)
            #expect(r.hint.id == RulesHintProvider.jsonID && r.hint.replacement == nil, "the ID is kept")
            #expect(!RulesHintProvider.formatsWholeJSONFile(r.hint, isStale: r.isStale), "\(String(describing: now))")
        }
        // The long one-line file's own hint (no range, never stale) still formats the whole file.
        let longLine = OwlHint(id: RulesHintProvider.jsonID, kind: .fix, title: "Looks like JSON. Format it?", source: "rules")
        c.markShown(longLine, documentID: doc, context: window(minified, doc: doc).context)
        let again = OwlCoordinator.replay(try #require(c.recent.first), document: "{}" as NSString)
        #expect(!again.isStale)
        #expect(RulesHintProvider.formatsWholeJSONFile(again.hint, isStale: again.isStale))
    }

    /// 0.5.4 QA #12: the stale JSON hint kept asking "Format it?" with no
    /// way to say yes. Checked again on the text now: still one-line JSON,
    /// a fresh hint for that text (its own replacement, never the
    /// whole-file formatter); not JSON, or closed, a past hint with no question.
    /// `replayJSON`, with a `.recheck` resolved as the app does (off the
    /// main thread, by `recheckJSON`).
    func json(_ r: OwlCoordinator.Replay, document: NSString?) -> OwlCoordinator.Replay {
        switch RulesHintProvider.replayJSON(r, document: document) {
        case .ready(let r): return r
        case .recheck(let text, let source):
            #expect(text == document.map { $0 as String }, "it checks the whole document now")
            return RulesHintProvider.recheckJSON(text, source: source)
        }
    }

    @Test func aStaleJSONHintIsCheckedAgainOnTheTextNow() throws {
        let (c, _) = make([])
        let doc = UUID()
        let minified = #"{"a":1,"b":[1,2]}"#
        let inView = OwlHint(id: RulesHintProvider.jsonID, kind: .fix, title: "Looks like JSON. Format it?",
                             range: NSRange(location: 0, length: (minified as NSString).length),
                             replacement: "{\n  \"a\" : 1,\n  \"b\" : [1, 2]\n}", source: "rules")
        c.markShown(inView, documentID: doc, context: window(minified, doc: doc).context)
        let shown = try #require(c.recent.first)

        // Unchanged: as before.
        let same = json(OwlCoordinator.replay(shown, document: minified as NSString), document: minified as NSString)
        #expect(same == OwlCoordinator.replay(shown, document: minified as NSString))
        #expect(RulesHintProvider.replayJSON(OwlCoordinator.replay(shown, document: minified as NSString), document: minified as NSString)
                == .ready(same), "nothing to check again")

        // Changed, still one-line JSON: the question, with a replacement for the text now.
        let now = #"{"a":2,"b":[3,4],"c":"x"}"# as NSString
        let again = json(OwlCoordinator.replay(shown, document: now), document: now)
        #expect(!again.isStale)
        #expect(again.hint.title == "Looks like JSON. Format it?")
        #expect(again.documentRange == NSRange(location: 0, length: now.length) && again.expected == now as String)
        #expect(again.hint.replacement == JSONFormatter.prettyIfMinified(now as String))
        #expect(again.hint.replacement != nil)
        #expect(!RulesHintProvider.formatsWholeJSONFile(again.hint, isStale: again.isStale), "its own Fix it, not the whole-file one")
        #expect(!RulesHintProvider.isPastJSONHint(again.hint))

        // Not JSON any more (or JSON over several lines, or empty): a past hint, no question.
        for text in ["not json at all", "{\n  \"a\": 1\n}", "", "{}"] as [NSString] {
            let r = json(OwlCoordinator.replay(shown, document: text), document: text)
            #expect(r.isStale && r.documentRange == nil && r.hint.replacement == nil && r.hint.range == nil)
            #expect(r.hint.title == "Looked like JSON (the text has changed since).", "\(text)")
            #expect(!r.hint.title.contains("?") && r.hint.detail == nil)
            #expect(RulesHintProvider.isPastJSONHint(r.hint))
            #expect(!RulesHintProvider.formatsWholeJSONFile(r.hint, isStale: r.isStale))
        }
        // Too long to check again: past, without checking.
        let long = ("[" + Array(repeating: "1", count: 40_000).joined(separator: ",") + "]") as NSString
        #expect(long.length > RulesHintProvider.replayJSONLimit)
        #expect(RulesHintProvider.replayJSON(OwlCoordinator.replay(shown, document: long), document: long)
                == .ready(RulesHintProvider.pastJSON(closed: false, source: "rules")))
        #expect(RulesHintProvider.isPastJSONHint(json(OwlCoordinator.replay(shown, document: long), document: long).hint))
        // Its document closed.
        let closed = json(OwlCoordinator.replay(shown, document: nil), document: nil)
        #expect(closed.hint.title == "Looked like JSON." && closed.isStale && RulesHintProvider.isPastJSONHint(closed.hint))

        // The long one-line file's hint (no range, never stale) is checked
        // again too (0.5.4 QA, should round 2: it asked "Format it?" over
        // "x", and Fix it then said the file isn't JSON). Other hints are
        // left alone.
        let longLine = OwlHint(id: RulesHintProvider.jsonID, kind: .fix, title: "Looks like JSON. Format it?", source: "rules")
        c.markShown(longLine, documentID: doc, context: window(minified, doc: doc).context)
        let l = OwlCoordinator.replay(try #require(c.recent.first), document: "x" as NSString)
        let lx = json(l, document: "x" as NSString)
        #expect(lx != l && RulesHintProvider.isPastJSONHint(lx.hint) && lx.hint.replacement == nil, "\"x\": a past hint, no question")
        #expect(!RulesHintProvider.formatsWholeJSONFile(lx.hint, isStale: lx.isStale))
        let lj = json(l, document: minified as NSString)
        #expect(!lj.isStale && lj.hint.replacement == JSONFormatter.prettyIfMinified(minified)
                && lj.documentRange == NSRange(location: 0, length: (minified as NSString).length), "still JSON: the question, for the text now")
        c.markShown(Self.doubled, documentID: doc, context: window(Self.text, doc: doc).context)
        let d = OwlCoordinator.replay(try #require(c.recent.first), document: "changed" as NSString)
        #expect(d.isStale && json(d, document: "changed" as NSString) == d)
    }

    /// Codex round 2: the range check alone passed text added after the
    /// JSON (the JSON a prefix of an invalid document), so Fix it offered
    /// to format the prefix; and the long one-line file's hint (no range)
    /// still asked "Format it?" with its document closed.
    @Test func aJSONHintWithTextAddedAfterItIsCheckedAgain() throws {
        let (c, _) = make([])
        let doc = UUID()
        let minified = #"{"a":1,"b":[1,2]}"#
        let inView = OwlHint(id: RulesHintProvider.jsonID, kind: .fix, title: "Looks like JSON. Format it?",
                             range: NSRange(location: 0, length: (minified as NSString).length),
                             replacement: "{\n  \"a\" : 1,\n  \"b\" : [1, 2]\n}", source: "rules")
        c.markShown(inView, documentID: doc, context: window(minified, doc: doc).context)
        let shown = try #require(c.recent.first)
        for grown in [minified + " and then some", minified + "}", minified + "\n{\"c\":3}"] {
            let now = grown as NSString
            let plain = OwlCoordinator.replay(shown, document: now)
            #expect(!plain.isStale, "the range still holds the JSON: \(grown)")
            guard case .recheck(let text, _) = RulesHintProvider.replayJSON(plain, document: now) else {
                Issue.record("not checked again: \(grown)"); continue
            }
            #expect(text == grown)
            let r = json(plain, document: now)
            #expect(RulesHintProvider.isPastJSONHint(r.hint) && r.hint.replacement == nil && r.documentRange == nil, "\(grown)")
        }
        // Added text that keeps it one-line JSON: a fresh hint for all of it.
        let spaced = (minified + "   ") as NSString
        let r = json(OwlCoordinator.replay(shown, document: spaced), document: spaced)
        #expect(!r.isStale && r.documentRange == NSRange(location: 0, length: spaced.length) && r.expected == spaced as String)

        // The long one-line file's hint: as it was while open, a past hint once closed.
        let longLine = OwlHint(id: RulesHintProvider.jsonID, kind: .fix, title: "Looks like JSON. Format it?", source: "rules")
        c.markShown(longLine, documentID: doc, context: window(minified, doc: doc).context)
        let l = try #require(c.recent.first)
        let closed = OwlCoordinator.replay(l, document: nil)
        #expect(!closed.isStale, "OwlCoordinator alone never calls it stale")
        #expect(RulesHintProvider.replayJSON(closed, document: nil) == .ready(RulesHintProvider.pastJSON(closed: true, source: "rules")))
        #expect(!RulesHintProvider.formatsWholeJSONFile(json(closed, document: nil).hint, isStale: json(closed, document: nil).isStale))
    }

    /// Codex round 2: 64 KB of input nested hundreds deep pretty-prints to
    /// tens of megabytes. Checked again, it is a past hint, not a 20 MB
    /// replacement; the formatter stops at the limit.
    @Test func deeplyNestedJSONIsNotFormattedPastTheOutputLimit() throws {
        let depth = 400
        let text = String(repeating: "[", count: depth) + Array(repeating: "1", count: 30_000).joined(separator: ",")
            + String(repeating: "]", count: depth)
        #expect((text as NSString).length <= RulesHintProvider.replayJSONLimit)
        let unbounded = JSONFormatter.prettyIfMinified(text)
        #expect((unbounded?.utf8.count ?? 0) > 20 * RulesHintProvider.replayJSONOutputLimit, "the case is real")
        #expect(JSONFormatter.prettyIfMinified(text, limit: RulesHintProvider.replayJSONOutputLimit) == nil)
        #expect(throws: TextToolError.self) { try JSONFormatter.format(text, pretty: true, limit: 1000) }
        let r = RulesHintProvider.recheckJSON(text, source: "rules")
        #expect(RulesHintProvider.isPastJSONHint(r.hint) && r.hint.replacement == nil)
        // Small enough: formatted as before.
        #expect(try JSONFormatter.format(#"{"a":[1]}"#, pretty: true, limit: 1000) == JSONFormatter.prettyIfMinified(#"{"a":[1]}"#))
        #expect(!RulesHintProvider.isPastJSONHint(RulesHintProvider.recheckJSON(#"{"a":[1]}"#, source: "rules").hint))
    }

    /// VoiceOver's label for a Recent hints row: "Format it?." in 0.5.4.
    @Test func theSpokenRowHasNoDoubledPunctuation() {
        #expect(OwlCoordinator.spokenRecent(time: "11:50 AM", title: "Looks like JSON. Format it?",
                                            detail: "Pretty-prints it with two-space indents; key order is kept.")
                == "11:50 AM, Looks like JSON. Format it? Pretty-prints it with two-space indents; key order is kept.")
        #expect(OwlCoordinator.spokenRecent(time: "9:00", title: "“the” twice", detail: "The word “the” is repeated.")
                == "9:00, “the” twice. The word “the” is repeated.")
        #expect(OwlCoordinator.spokenRecent(time: "9:00", title: "Looked like JSON.", detail: "x") == "9:00, Looked like JSON. x")
        #expect(OwlCoordinator.spokenRecent(time: "9:00", title: "Fix 3 typos?", detail: nil) == "9:00, Fix 3 typos?")
        #expect(OwlCoordinator.spokenRecent(time: "9:00", title: "Hi!", detail: "") == "9:00, Hi!")
        let long = String(repeating: "a", count: 130)
        #expect(OwlCoordinator.spokenRecent(time: "t", title: "T", detail: long) == "t, T. " + String(repeating: "a", count: 120) + "…")
        for title in ["Fix it?", "Done.", "Wow!", "Wait…"] {
            let s = OwlCoordinator.spokenRecent(time: "t", title: title, detail: "More.")
            #expect(!s.contains("?.") && !s.contains("..") && !s.contains("!.") && !s.contains("….") , "\(s)")
        }
    }

    /// 0.5.4 QA (should round 2): past the length checked again, the long
    /// one-line file's hint keeps its question only while the text still
    /// has one-line JSON's shape (its Fix it parses the whole file before
    /// formatting); plain text there is a past hint.
    @Test func aLongRangelessJSONHintKeepsItsQuestionOnlyForJSONShapedText() throws {
        let (c, _) = make([])
        let doc = UUID()
        let longLine = OwlHint(id: RulesHintProvider.jsonID, kind: .fix, title: "Looks like JSON. Format it?", source: "rules")
        c.markShown(longLine, documentID: doc, context: window("[1]", doc: doc).context)
        let shown = try #require(c.recent.first)
        let long = (" [" + Array(repeating: "1", count: 40_000).joined(separator: ",") + "]\n") as NSString
        #expect(long.length > RulesHintProvider.replayJSONLimit)
        let r = OwlCoordinator.replay(shown, document: long)
        #expect(RulesHintProvider.replayJSON(r, document: long) == .ready(r), "JSON-shaped: the question, Fix it checks the file")
        #expect(RulesHintProvider.formatsWholeJSONFile(r.hint, isStale: r.isStale))
        for text in [String(repeating: "plain text ", count: 7000), "[" + String(repeating: "1,\n", count: 30_000) + "1]",
                     "{" + String(repeating: "a", count: 70_000) + "]"] {
            let ns = text as NSString
            #expect(ns.length > RulesHintProvider.replayJSONLimit)
            #expect(RulesHintProvider.replayJSON(OwlCoordinator.replay(shown, document: ns), document: ns)
                    == .ready(RulesHintProvider.pastJSON(closed: false, source: "rules")), "\(text.prefix(12))…: past")
        }
    }

    /// 0.5.4 QA (should round 2): Fix it checked that the hint's range
    /// still held its text with Swift's `==` (canonical equivalence: "Å"
    /// matched "A" + ring, and the fix wrote the old scalar back), and for
    /// the JSON hint not that the range was still the whole document (text
    /// typed after the JSON while the bubble showed had the JSON prefix
    /// formatted and the rest left).
    @Test func aFixStillAppliesOnlyToTheSameUnitsAndJSONToTheWholeText() {
        let json = OwlHint(id: RulesHintProvider.jsonID, kind: .fix, title: "Looks like JSON. Format it?",
                           range: NSRange(location: 0, length: 9), replacement: "{\n  \"a\" : \"\u{C5}\"\n}", source: "rules")
        let text = "{\"a\":\"\u{C5}\"}"
        let all = NSRange(location: 0, length: (text as NSString).length)
        #expect(RulesHintProvider.stillApplies(json, range: all, expected: text, in: text as NSString))
        // The same text, decomposed: equal to Swift, not the same units.
        let decomposed = "{\"a\":\"A\u{30A}\"}"
        #expect(decomposed == text, "the case is real")
        let wholeDecomposed = NSRange(location: 0, length: (decomposed as NSString).length)
        #expect(!RulesHintProvider.stillApplies(json, range: wholeDecomposed, expected: text, in: decomposed as NSString))
        // Text added after the JSON: the range still holds it, not the whole text.
        let grown = (text + " trailing") as NSString
        #expect(grown.substring(with: all) == text)
        #expect(!RulesHintProvider.stillApplies(json, range: all, expected: text, in: grown))
        // Another hint's range inside a longer text applies as before.
        let other = OwlHint(id: RulesHintProvider.duplicateWordID, kind: .fix, title: "x", source: "rules")
        #expect(RulesHintProvider.stillApplies(other, range: NSRange(location: 0, length: 3), expected: "the", in: "the the end"))
        #expect(!RulesHintProvider.stillApplies(other, range: NSRange(location: 0, length: 3), expected: "the", in: "th"))
    }
}
