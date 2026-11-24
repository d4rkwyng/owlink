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
}
