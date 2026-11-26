import Foundation
import Testing
@testable import CedricCore

@Suite struct SpellCheckCoverageTests {
    let orthography: UInt64 = 1 << 0
    let spelling: UInt64 = 1 << 1
    let grammar: UInt64 = 1 << 2
    let correction: UInt64 = 1 << 9
    /// AppKit's private bits, as seen on macOS 27: the view's enabled
    /// types carry bit 13, its scheduled pass bit 28.
    let completion: UInt64 = 1 << 13
    let scheduledPrivate: UInt64 = 1 << 28

    var enabled: UInt64 { orthography | spelling | completion }
    /// As measured on macOS 27 (spellopen): 0x10002003.
    var scheduled: UInt64 { orthography | spelling | completion | scheduledPrivate }

    let dict = SpellDictionaryState(language: "en", automaticByLanguage: true, ignored: [])

    /// The early check of `r`, its results back.
    func covering(_ r: NSRange, marking words: [String] = []) -> SpellCheckCoverage {
        var c = SpellCheckCoverage()
        c.checked(r, types: SpellCheckCoverage.earlyTypes(enabled: enabled), dictionary: dict)
        c.resultsArrived(for: r, marking: words)
        return c
    }

    @Test func earlyTypesAreThePublicEnabledOnesPlusCorrection() {
        #expect(SpellCheckCoverage.earlyTypes(enabled: enabled) == orthography | spelling | correction)
        #expect(SpellCheckCoverage.earlyTypes(enabled: spelling | grammar) == spelling | grammar | correction)
    }

    /// The pass AppKit schedules after the first layout, as measured on the
    /// 1 MB benchmark file: the same range, its own types.
    @Test func skipsAppKitsPassOverTheCheckedRange() {
        var c = covering(NSRange(location: 0, length: 2899))
        let took1 = c.take(NSRange(location: 0, length: 2899), types: scheduled, dictionary: dict)
        #expect(took1)
    }

    @Test func skipsARangeInsideTheCheckedOne() {
        var c = covering(NSRange(location: 100, length: 3000))
        let took2 = c.take(NSRange(location: 100, length: 10), types: scheduled, dictionary: dict)
        #expect(took2)
        var d = covering(NSRange(location: 100, length: 3000))
        let took3 = d.take(NSRange(location: 3090, length: 10), types: scheduled, dictionary: dict)
        #expect(took3)
        var e = covering(NSRange(location: 100, length: 3000))
        let took4 = e.take(NSRange(location: 3100, length: 0), types: scheduled, dictionary: dict)
        #expect(took4)
    }

    @Test func checksARangeThatReachesOutside() {
        var before = covering(NSRange(location: 100, length: 3000))
        let took5 = before.take(NSRange(location: 99, length: 10), types: scheduled, dictionary: dict)
        #expect(!took5)
        var after = covering(NSRange(location: 100, length: 3000))
        let took6 = after.take(NSRange(location: 3095, length: 10), types: scheduled, dictionary: dict)
        #expect(!took6)
        var bigger = covering(NSRange(location: 100, length: 3000))
        let took7 = bigger.take(NSRange(location: 0, length: 1_000_000), types: scheduled, dictionary: dict)
        #expect(!took7)
    }

    @Test func checksATypeTheEarlyCheckDidNotAskFor() {
        var c = covering(NSRange(location: 0, length: 2899))
        let took8 = c.take(NSRange(location: 0, length: 2899), types: scheduled | grammar, dictionary: dict)
        #expect(!took8)
    }

    @Test func skipsWithAppKitsKnownPrivateBits() {
        var c = covering(NSRange(location: 0, length: 2899))
        let took9 = c.take(NSRange(location: 0, length: 2899), types: spelling | scheduledPrivate | completion, dictionary: dict)
        #expect(took9)
    }

    /// A bit nobody has seen AppKit's pass use: the early check can't vouch for it.
    @Test func checksARequestWithAnUnknownBit() {
        for bit in [UInt64(14), 20, 27, 29, 31, 40] {
            var c = covering(NSRange(location: 0, length: 2899))
            let took = c.take(NSRange(location: 0, length: 2899), types: scheduled | (1 << bit), dictionary: dict)
            #expect(!took, "bit \(bit)")
            #expect(c.isEmpty)
        }
    }

    /// AppKit's scheduled pass passes no options; one that does isn't it.
    @Test func checksARequestWithOptions() {
        var c = covering(NSRange(location: 0, length: 2899))
        let took = c.take(NSRange(location: 0, length: 2899), types: scheduled, hasOptions: true, dictionary: dict)
        #expect(!took)
        #expect(c.isEmpty)
    }

    /// Ignore (in the spelling panel or the context menu) between the early
    /// reply and AppKit's pass: the marks must be rebuilt.
    @Test func checksAfterAWordIsIgnored() {
        var c = covering(NSRange(location: 0, length: 2899), marking: ["tpyo", "wrnog"])
        var now = dict
        now.ignored = ["tpyo"]
        let took = c.take(NSRange(location: 0, length: 2899), types: scheduled, dictionary: now)
        #expect(!took)
    }

    /// Learn Word on a marked word: it is no longer misspelled.
    @Test func checksAfterAMarkedWordIsLearned() {
        var c = covering(NSRange(location: 0, length: 2899), marking: ["tpyo", "wrnog"])
        #expect(c.markedWords == ["tpyo", "wrnog"])
        var now = dict
        now.learned = ["tpyo"]
        let took = c.take(NSRange(location: 0, length: 2899), types: scheduled, dictionary: now)
        #expect(!took)
    }

    @Test func checksAfterALanguageChange() {
        for change in [{ (d: inout SpellDictionaryState) in d.language = "fr" }, { $0.automaticByLanguage = false }] {
            var c = covering(NSRange(location: 0, length: 2899))
            var now = dict
            change(&now)
            let took = c.take(NSRange(location: 0, length: 2899), types: scheduled, dictionary: now)
            #expect(!took)
        }
    }

    /// The marked words are the early check's own: a later batch for
    /// another range doesn't replace them, nor does a second batch.
    @Test func theMarkedWordsAreTheEarlyChecks() {
        var c = SpellCheckCoverage()
        let r = NSRange(location: 0, length: 2899)
        c.checked(r, types: SpellCheckCoverage.earlyTypes(enabled: enabled), dictionary: dict)
        c.resultsArrived(for: NSRange(location: 0, length: 10), marking: ["other"])
        #expect(c.markedWords.isEmpty && !c.answered)
        c.resultsArrived(for: r, marking: ["tpyo"])
        c.resultsArrived(for: r, marking: ["again"])
        #expect(c.markedWords == ["tpyo"])
        c.clear()
        #expect(c.markedWords.isEmpty && c.dictionary == nil)
    }

    /// One-shot: whatever the first request was, the next one is checked.
    @Test func onlyTheFirstRequestIsEverSkipped() {
        var c = covering(NSRange(location: 0, length: 2899))
        let took10 = c.take(NSRange(location: 0, length: 2899), types: scheduled, dictionary: dict)
        #expect(took10)
        #expect(c.isEmpty)
        let took11 = c.take(NSRange(location: 0, length: 2899), types: scheduled, dictionary: dict)
        #expect(!took11)

        var d = covering(NSRange(location: 0, length: 2899))
        let took12 = d.take(NSRange(location: 5000, length: 2899), types: scheduled, dictionary: dict)
        #expect(!took12)
        #expect(d.isEmpty)
        let took13 = d.take(NSRange(location: 0, length: 2899), types: scheduled, dictionary: dict)
        #expect(!took13)
    }

    @Test func anEditClearsIt() {
        var c = covering(NSRange(location: 0, length: 2899))
        c.clear()
        #expect(c.isEmpty)
        let took14 = c.take(NSRange(location: 0, length: 2899), types: scheduled, dictionary: dict)
        #expect(!took14)
    }

    /// Until the early check's own results are back, AppKit's pass is
    /// what will mark the text: it runs.
    @Test func skipsNothingUntilTheEarlyResultsAreBack() {
        var c = SpellCheckCoverage()
        let r = NSRange(location: 0, length: 2899)
        c.checked(r, types: SpellCheckCoverage.earlyTypes(enabled: enabled), dictionary: dict)
        #expect(!c.isEmpty && !c.answered)
        let took15 = c.take(r, types: scheduled, dictionary: dict)
        #expect(!took15)
        #expect(c.isEmpty)
    }

    @Test func onlyTheEarlyChecksOwnResultsCount() {
        var c = SpellCheckCoverage()
        let r = NSRange(location: 0, length: 2899)
        c.checked(r, types: SpellCheckCoverage.earlyTypes(enabled: enabled), dictionary: dict)
        c.resultsArrived(for: NSRange(location: 0, length: 100))
        #expect(!c.answered)
        c.resultsArrived(for: r)
        #expect(c.answered)
        let took16 = c.take(r, types: scheduled, dictionary: dict)
        #expect(took16)
    }

    @Test func aNewEarlyCheckWaitsForItsOwnResults() {
        var c = covering(NSRange(location: 0, length: 2899))
        c.checked(NSRange(location: 0, length: 2899), types: SpellCheckCoverage.earlyTypes(enabled: enabled), dictionary: dict)
        #expect(!c.answered)
    }

    @Test func nothingCheckedSkipsNothing() {
        var c = SpellCheckCoverage()
        let took17 = c.take(NSRange(location: 0, length: 0), types: spelling, dictionary: dict)
        #expect(!took17)
    }
}
