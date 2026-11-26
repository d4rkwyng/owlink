import Foundation
import Testing
@testable import CedricCore

/// The learned-word path of the first-frame spell check's skip decision,
/// through the spelling-dictionary seam the app uses (SpellDictionaryService),
/// with the recording dictionary the checks use: nothing here touches the
/// user's real spelling dictionary.
@Suite struct SpellDictionaryServiceTests {
    let enabled: UInt64 = (1 << 0) | (1 << 1) | (1 << 13)
    /// AppKit's scheduled pass, as measured on macOS 27 (spellopen).
    let scheduled: UInt64 = (1 << 0) | (1 << 1) | (1 << 13) | (1 << 28)
    let page = NSRange(location: 0, length: 2899)
    let tag = 7
    let ownPID: Int32 = 4242

    /// The view's record, as the learned-word notice reaches it.
    final class View: @unchecked Sendable {
        var coverage = SpellCheckCoverage()
    }

    /// The early check of `page` through `d`, its results back marking `words`.
    func early(_ d: SpellDictionaryService, marking words: [String] = ["tpyo", "wrnog"], onlyOwlinkInFront: Bool = true) -> SpellCheckCoverage {
        var c = SpellCheckCoverage()
        c.checked(page, types: SpellCheckCoverage.earlyTypes(enabled: enabled), dictionary: d, tag: tag, onlyOwlinkInFront: onlyOwlinkInFront)
        c.resultsArrived(for: page, marking: words)
        return c
    }

    /// Nothing changed, Owlink in front all along: skipped, without one
    /// question about learned words.
    @Test func inFrontAllAlongSkipsWithoutAsking() {
        let d = RecordingSpellDictionary()
        var c = early(d)
        let took = c.takeAppKitPass(page, types: scheduled, hasOptions: false, onlyOwlinkInFront: true, dictionary: d, tag: tag)
        #expect(took)
        #expect(d.asked.isEmpty)
    }

    /// A word learned in Owlink: the dictionary's notice clears the record
    /// (SpellLearnedWatch, as the view uses it), so AppKit's pass runs.
    /// Released, the watch hears nothing more.
    @Test func learnedInProcessClearsTheRecord() {
        let d = RecordingSpellDictionary()
        let view = View()
        view.coverage = early(d)
        var watch: SpellLearnedWatch? = SpellLearnedWatch(d) { view.coverage.clear() }
        #expect(watch != nil)
        d.learnWord("tpyo")
        #expect(d.learnCalls == ["tpyo"])
        #expect(view.coverage.isEmpty)
        let took = view.coverage.takeAppKitPass(page, types: scheduled, hasOptions: false, onlyOwlinkInFront: true, dictionary: d, tag: tag)
        #expect(!took)

        watch = nil
        view.coverage = early(d, marking: ["wrnog"])
        d.learnWord("other")
        #expect(!view.coverage.isEmpty)
    }

    /// Another app came to the front after the early check and learned a
    /// marked word there (no notice): AppKit's pass asks about the marked
    /// words and runs.
    @Test func learnedInAnotherAppAfterItCameToTheFrontIsCaught() {
        let d = RecordingSpellDictionary()
        var c = early(d)
        #expect(SpellFrontApp.mayLearnElsewhere(activated: (pid: 99, bundleID: "com.apple.finder"), ownPID: ownPID))
        c.anotherAppInFront()
        d.learnElsewhere("tpyo")
        let took = c.takeAppKitPass(page, types: scheduled, hasOptions: false, onlyOwlinkInFront: true, dictionary: d, tag: tag)
        #expect(!took)
        #expect(d.asked == ["tpyo", "wrnog"])
    }

    /// Owlink wasn't in front at the early check (opened in the background),
    /// or another app is in front at AppKit's pass: a word learned there is
    /// caught.
    @Test func learnedWhileOwlinkWasNotInFrontIsCaught() {
        let atEarly = RecordingSpellDictionary()
        var c = early(atEarly, onlyOwlinkInFront: false)
        atEarly.learnElsewhere("wrnog")
        let tookEarly = c.takeAppKitPass(page, types: scheduled, hasOptions: false, onlyOwlinkInFront: true, dictionary: atEarly, tag: tag)
        #expect(!tookEarly)
        #expect(atEarly.asked == ["tpyo", "wrnog"])

        let atPass = RecordingSpellDictionary()
        var p = early(atPass)
        atPass.learnElsewhere("tpyo")
        let tookPass = p.takeAppKitPass(page, types: scheduled, hasOptions: false, onlyOwlinkInFront: false, dictionary: atPass, tag: tag)
        #expect(!tookPass)
        #expect(atPass.asked == ["tpyo", "wrnog"])

        // Another app in front, nothing learned: asked, and still skipped.
        let quiet = RecordingSpellDictionary()
        var q = early(quiet, onlyOwlinkInFront: false)
        let tookQuiet = q.takeAppKitPass(page, types: scheduled, hasOptions: false, onlyOwlinkInFront: false, dictionary: quiet, tag: tag)
        #expect(tookQuiet)
        #expect(quiet.asked == ["tpyo", "wrnog"])
    }

    /// The accepted gap: a word learned with no notice while Owlink stays
    /// in front (a background script) isn't asked about.
    @Test func learnedWithoutNoticeWhileInFrontIsNotAsked() {
        let d = RecordingSpellDictionary()
        var c = early(d)
        d.learnElsewhere("tpyo")
        let took = c.takeAppKitPass(page, types: scheduled, hasOptions: false, onlyOwlinkInFront: true, dictionary: d, tag: tag)
        #expect(took)
        #expect(d.asked.isEmpty)
    }

    /// The lock screen in front counts as Owlink in front: nobody types
    /// into another app behind it. Owlink itself activating doesn't count
    /// either; any other app, or Owlink resigning active, does.
    @Test func lockScreenCountsAsOwlinkInFront() {
        #expect(SpellFrontApp.onlyOwlinkInFront(isActive: false, frontmostBundleID: "com.apple.loginwindow"))
        #expect(!SpellFrontApp.onlyOwlinkInFront(isActive: false, frontmostBundleID: "com.apple.finder"))
        #expect(!SpellFrontApp.onlyOwlinkInFront(isActive: false, frontmostBundleID: nil))
        var read = false
        // Active: the frontmost app isn't looked up (outside #expect, which evaluates its parts).
        let active = SpellFrontApp.onlyOwlinkInFront(isActive: true, frontmostBundleID: { read = true; return "com.apple.finder" }())
        #expect(active)
        #expect(!read)

        #expect(!SpellFrontApp.mayLearnElsewhere(activated: (pid: 88, bundleID: SpellFrontApp.lockScreen), ownPID: ownPID))
        #expect(!SpellFrontApp.mayLearnElsewhere(activated: (pid: ownPID, bundleID: "net.example.owlink"), ownPID: ownPID))
        #expect(SpellFrontApp.mayLearnElsewhere(activated: (pid: 99, bundleID: "com.apple.finder"), ownPID: ownPID))
        #expect(SpellFrontApp.mayLearnElsewhere(activated: (pid: 99, bundleID: nil), ownPID: ownPID))
        #expect(SpellFrontApp.mayLearnElsewhere(activated: nil, ownPID: ownPID))

        // Opened with the screen locked, the pass with it still locked: skipped unasked.
        let d = RecordingSpellDictionary()
        let locked = SpellFrontApp.onlyOwlinkInFront(isActive: false, frontmostBundleID: SpellFrontApp.lockScreen)
        var c = early(d, onlyOwlinkInFront: locked)
        #expect(!c.asksLearned)
        let took = c.takeAppKitPass(page, types: scheduled, hasOptions: false, onlyOwlinkInFront: locked, dictionary: d, tag: tag)
        #expect(took)
        #expect(d.asked.isEmpty)
    }

    /// Fix Typos' Ignore All through the seam: ignored in that document
    /// only, and AppKit's pass over it runs.
    @Test func ignoredInTheDocumentIsCaught() {
        let d = RecordingSpellDictionary()
        var c = early(d)
        d.ignoreWord("tpyo", inSpellDocumentWithTag: tag)
        #expect(d.ignoreCalls == ["tpyo"])
        let took = c.takeAppKitPass(page, types: scheduled, hasOptions: false, onlyOwlinkInFront: true, dictionary: d, tag: tag)
        #expect(!took)

        // A word ignored in another document changes nothing here.
        var next = early(d)
        d.ignoreWord("wrnog", inSpellDocumentWithTag: tag + 1)
        let tookNext = next.takeAppKitPass(page, types: scheduled, hasOptions: false, onlyOwlinkInFront: true, dictionary: d, tag: tag)
        #expect(tookNext)
    }

    /// No record: nothing is asked and nothing skipped.
    @Test func noRecordAsksNothing() {
        let d = RecordingSpellDictionary()
        var c = SpellCheckCoverage()
        let took = c.takeAppKitPass(page, types: scheduled, hasOptions: false, onlyOwlinkInFront: false, dictionary: d, tag: tag)
        #expect(!took)
        #expect(d.asked.isEmpty)
    }

    /// The check's dictionary drops the real spell checker's marks on its
    /// own learned words and on words ignored in that document only.
    @Test func recordingDictionarySuppressesItsOwnWords() {
        let d = RecordingSpellDictionary()
        #expect(d.suppressesMarks)
        #expect(!d.suppressesMark("tpyo", inSpellDocumentWithTag: tag))
        d.ignoreWord("tpyo", inSpellDocumentWithTag: tag)
        d.learnWord("wrnog")
        #expect(d.suppressesMark("tpyo", inSpellDocumentWithTag: tag))
        #expect(!d.suppressesMark("tpyo", inSpellDocumentWithTag: tag + 1))
        #expect(d.suppressesMark("wrnog", inSpellDocumentWithTag: tag + 1))
    }
}
