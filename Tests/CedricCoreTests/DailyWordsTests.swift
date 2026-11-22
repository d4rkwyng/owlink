import Foundation
import Testing
@testable import CedricCore

@Suite struct DailyWordsTests {
    @Test func logPersistsNetChangesAndTargetAcrossReloads() {
        let (defaults, suite) = TestDefaults.make("cedric-tests-")
        defer { TestDefaults.remove(suite) }
        let now = Date()
        let day = DailyWords.dayString(for: now)
        var log = DailyWordLog.load(now: now, defaults: defaults)
        log.rebaseline(key: "first", words: 100)
        log.rebaseline(key: "second", words: 10)
        let first = log.note(key: "first", words: 105, on: day)
        let second = log.note(key: "second", words: 12, on: day)
        let deletion = log.note(key: "first", words: 103, on: day)
        #expect(first && second && deletion)
        DailyWordDefaults.setWords(log.wordsToday, on: day, defaults: defaults)
        let changed = log.setTarget(500)
        #expect(changed)
        DailyWordDefaults.setTarget(log.target, in: defaults)
        let restored = DailyWordLog.load(now: now, defaults: defaults)
        #expect(restored.wordsToday == 5)
        #expect(restored.target == 500)
        #expect(restored.ledger.counts.isEmpty)
    }

    /// 2026-11-21 00:30 in Tokyo is still 2026-11-20 in Los Angeles.
    /// November 2026 is Japan standard time (UTC+9) and Pacific standard
    /// time (UTC−8; US daylight time ended on 1 November 2026).
    private func acrossMidnight() -> Date {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var parts = DateComponents()
        parts.calendar = tokyo
        parts.timeZone = tokyo.timeZone
        parts.year = 2026
        parts.month = 11
        parts.day = 21
        parts.hour = 0
        parts.minute = 30
        return tokyo.date(from: parts)!
    }

    @Test func dayRollsOverAtLocalMidnight() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let instant = acrossMidnight()
        #expect(DailyWords.dayString(for: instant, calendar: tokyo) == "2026-11-21")
        #expect(DailyWords.dayString(for: instant, calendar: losAngeles) == "2026-11-20")

        let yesterday = DailyWords(day: "2026-11-20", words: 400)
        #expect(yesterday.rolled(to: "2026-11-21") == DailyWords(day: "2026-11-21", words: 0))
        #expect(yesterday.rolled(to: "2026-11-20").words == 400)
        // A stored negative is not a count.
        #expect(DailyWords(day: "2026-11-20", words: -5).words == 0)

        // No new writing after midnight: the total is zero, and yesterday's
        // 400 is not carried. The baseline stays, so the file's existing
        // words are not counted as written today.
        var ledger = DailyWordLedger(words: yesterday, counts: ["essay": 1000])
        ledger = ledger.noting(key: "essay", current: 1000, on: "2026-11-21")
        #expect(ledger.words == DailyWords(day: "2026-11-21", words: 0))
        #expect(ledger.counts["essay"] == 1000)
        // Growth after midnight counts on the new day only.
        ledger = ledger.noting(key: "essay", current: 1030, on: "2026-11-21")
        #expect(ledger.words.words == 30)
        // A delete that crosses midnight on a fresh day stops at zero.
        var fresh = DailyWordLedger(words: yesterday, counts: ["essay": 1000])
        fresh = fresh.noting(key: "essay", current: 990, on: "2026-11-21")
        #expect(fresh.words.words == 0)

        // Persisted by the local day: today's key is not yesterday's count.
        let (defaults, suite) = TestDefaults.make("cedric-tests-")
        defer { TestDefaults.remove(suite) }
        #expect(DailyWordDefaults.target(in: defaults) == nil)
        #expect(DailyWordDefaults.words(on: "2026-11-21", defaults: defaults) == 0)
        DailyWordDefaults.setWords(400, on: "2026-11-20", defaults: defaults)
        #expect(DailyWordDefaults.words(on: "2026-11-21", defaults: defaults) == 0)
        #expect(DailyWordDefaults.words(on: "2026-11-20", defaults: defaults) == 400)
        #expect(DailyWordDefaults.countKey(day: "2026-11-21") == "dailyWords.2026-11-21")
        DailyWordDefaults.setWords(30, on: "2026-11-21", defaults: defaults)
        #expect(DailyWordDefaults.words(on: "2026-11-21", defaults: defaults) == 30)
        #expect(DailyWordDefaults.words(on: "2026-11-20", defaults: defaults) == 400)
        // The target is not part of the day. Absent, zero or junk is off.
        #expect(DailyWordLog.load(now: instant, calendar: losAngeles, defaults: defaults).wordsToday == 400)
        #expect(DailyWordLog.load(now: instant, calendar: tokyo, defaults: defaults).wordsToday == 30)
        #expect(DailyWordLog.load(now: instant, calendar: tokyo, defaults: defaults).target == nil)
        DailyWordDefaults.setTarget(500, in: defaults)
        #expect(DailyWordDefaults.target(in: defaults) == 500)
        DailyWordDefaults.setTarget(0, in: defaults)
        #expect(DailyWordDefaults.target(in: defaults) == nil)
        DailyWordDefaults.setTarget(nil, in: defaults)
        #expect(defaults.object(forKey: DailyWordDefaults.targetKey) == nil)
    }

    @Test func netDeltaNeverGoesBelowZero() {
        var ledger = DailyWordLedger(words: DailyWords(day: "2026-11-21", words: 0))
        // Opening a file records its words and adds nothing.
        ledger = ledger.noting(key: "a", current: 500, on: "2026-11-21")
        #expect(ledger.words.words == 0)
        #expect(ledger.counts["a"] == 500)
        // Writing in two documents adds both.
        ledger = ledger.noting(key: "a", current: 520, on: "2026-11-21")
        ledger = ledger.noting(key: "b", current: 0, on: "2026-11-21")
        ledger = ledger.noting(key: "b", current: 10, on: "2026-11-21")
        #expect(ledger.words.words == 30)
        // Deleting some of today's words takes them back.
        ledger = ledger.noting(key: "a", current: 510, on: "2026-11-21")
        #expect(ledger.words.words == 20)
        // Deleting more than was written today stops at zero.
        ledger = ledger.noting(key: "a", current: 100, on: "2026-11-21")
        #expect(ledger.words.words == 0)
        // Further deletes stay at zero: no debt into the next note.
        ledger = ledger.noting(key: "b", current: 0, on: "2026-11-21")
        #expect(ledger.words.words == 0)
        // New words after that count again, from the new baseline.
        ledger = ledger.noting(key: "b", current: 4, on: "2026-11-21")
        #expect(ledger.words.words == 4)
        // The clamp is on the day's total.
        #expect(DailyWords(day: "2026-11-21", words: 10).adding(delta: -25, on: "2026-11-21").words == 0)
        #expect(DailyWords(day: "2026-11-21", words: 10).adding(delta: -4, on: "2026-11-21").words == 6)
        #expect(DailyWords(day: "2026-11-21", words: 0).adding(delta: -1, on: "2026-11-21").words == 0)
        #expect(DailyWords(day: "2026-11-21", words: 0).adding(delta: 7, on: "2026-11-21").words == 7)
        // A baseline that arrives after the first note still counts the
        // words typed before it, and only once.
        var late = DailyWordLedger(words: DailyWords(day: "2026-11-21", words: 0))
        late = late.noting(key: "a", current: 12, on: "2026-11-21")
        #expect(late.words.words == 0)
        late = late.rebasing(key: "a", original: 5, on: "2026-11-21")
        #expect(late.words.words == 7)
        #expect(late.counts["a"] == 12)
        late = late.rebasing(key: "a", original: 5, on: "2026-11-21")
        #expect(late.words.words == 7)
        // A reload replaces the baseline and does not count the file's text.
        late = late.rebaselined(key: "a", words: 400)
        late = late.noting(key: "a", current: 400, on: "2026-11-21")
        #expect(late.words.words == 7)
    }
}
