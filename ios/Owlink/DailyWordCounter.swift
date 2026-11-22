import UIKit
import CedricCore

@MainActor
final class DailyWordCounter {
    static let shared = DailyWordCounter()
    static let changed = Notification.Name("OwlinkDailyWordsChanged")

    private let defaults: UserDefaults
    private var log: DailyWordLog
    private let calendar: Calendar
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        log = DailyWordLog.load(now: now(), calendar: calendar, defaults: defaults)
    }

    var wordsToday: Int { log.wordsToday }
    var target: Int? { log.target }

    func rebaseline(key: String, words: Int?) {
        if let words { log.rebaseline(key: key, words: words) } else { log.drop(key) }
    }

    func note(key: String, words: Int?) {
        guard let words else { log.drop(key); return }
        let day = DailyWords.dayString(for: now(), calendar: calendar)
        if log.note(key: key, words: words, on: day) {
            DailyWordDefaults.setWords(log.wordsToday, on: log.day, defaults: defaults)
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    func drop(_ key: String) { log.drop(key) }

    func setTarget(_ target: Int?) {
        guard log.setTarget(target) else { return }
        DailyWordDefaults.setTarget(log.target, in: defaults)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    func roll() {
        if log.roll(to: DailyWords.dayString(for: now(), calendar: calendar)) {
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
}
