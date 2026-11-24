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
        let same = RulesHintProvider.replayJSON(OwlCoordinator.replay(shown, document: minified as NSString), document: minified as NSString)
        #expect(same == OwlCoordinator.replay(shown, document: minified as NSString))

        // Changed, still one-line JSON: the question, with a replacement for the text now.
        let now = #"{"a":2,"b":[3,4],"c":"x"}"# as NSString
        let again = RulesHintProvider.replayJSON(OwlCoordinator.replay(shown, document: now), document: now)
        #expect(!again.isStale)
        #expect(again.hint.title == "Looks like JSON. Format it?")
        #expect(again.documentRange == NSRange(location: 0, length: now.length) && again.expected == now as String)
        #expect(again.hint.replacement == JSONFormatter.prettyIfMinified(now as String))
        #expect(again.hint.replacement != nil)
        #expect(!RulesHintProvider.formatsWholeJSONFile(again.hint, isStale: again.isStale), "its own Fix it, not the whole-file one")
        #expect(!RulesHintProvider.isPastJSONHint(again.hint))

        // Not JSON any more (or JSON over several lines, or empty): a past hint, no question.
        for text in ["not json at all", "{\n  \"a\": 1\n}", "", "{}"] as [NSString] {
            let r = RulesHintProvider.replayJSON(OwlCoordinator.replay(shown, document: text), document: text)
            #expect(r.isStale && r.documentRange == nil && r.hint.replacement == nil && r.hint.range == nil)
            #expect(r.hint.title == "Looked like JSON (the text has changed since).", "\(text)")
            #expect(!r.hint.title.contains("?") && r.hint.detail == nil)
            #expect(RulesHintProvider.isPastJSONHint(r.hint))
            #expect(!RulesHintProvider.formatsWholeJSONFile(r.hint, isStale: r.isStale))
        }
        // Too long to check again on the main thread: past.
        let long = ("[" + Array(repeating: "1", count: 40_000).joined(separator: ",") + "]") as NSString
        #expect(long.length > RulesHintProvider.replayJSONLimit)
        #expect(RulesHintProvider.isPastJSONHint(RulesHintProvider.replayJSON(OwlCoordinator.replay(shown, document: long), document: long).hint))
        // Its document closed.
        let closed = RulesHintProvider.replayJSON(OwlCoordinator.replay(shown, document: nil), document: nil)
        #expect(closed.hint.title == "Looked like JSON." && closed.isStale && RulesHintProvider.isPastJSONHint(closed.hint))

        // Other hints and the long one-line file's hint (never stale) are left alone.
        let longLine = OwlHint(id: RulesHintProvider.jsonID, kind: .fix, title: "Looks like JSON. Format it?", source: "rules")
        c.markShown(longLine, documentID: doc, context: window(minified, doc: doc).context)
        let l = OwlCoordinator.replay(try #require(c.recent.first), document: "x" as NSString)
        #expect(RulesHintProvider.replayJSON(l, document: "x" as NSString) == l)
        c.markShown(Self.doubled, documentID: doc, context: window(Self.text, doc: doc).context)
        let d = OwlCoordinator.replay(try #require(c.recent.first), document: "changed" as NSString)
        #expect(d.isStale && RulesHintProvider.replayJSON(d, document: "changed" as NSString) == d)
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
}
