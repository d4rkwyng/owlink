import Foundation

/// UserDefaults for tests: process-local and in memory, never cfprefsd.
///
/// Tests used to get real UserDefaults suites named by a path in
/// `TMPDIR/cedric-test-prefs`. On a fresh, loaded CI runner two tests read
/// back a value after it had been overwritten or removed
/// (DefaultEditorModelTests.tickAndUntick, OwlCoordinatorTests.dontShowAgainIsSaved),
/// and a real suite also sees the global and argument domains. So a suite
/// is now an `InMemoryDefaults`, a UserDefaults subclass whose primitives
/// read and write a dictionary under a lock: a write is visible to the next
/// read straight away, and nothing outside the test is visible at all.
///
/// A suite stays registered by name until `remove`, so
/// `TestDefaults.defaults(name)` hands out the same store again, the way a
/// new `UserDefaults(suiteName:)` (the next launch) sees what was saved.
/// Names are still paths in `TMPDIR/cedric-test-prefs`: the superclass is
/// given that name, so if anything ever reached the real store it would
/// land there, and `remove` deletes that plist too. Scripts/test.sh still
/// sweeps stale ones from there and ~/Library/Preferences.
enum TestDefaults {
    /// Every prefix a Cedric test suite name starts with (test.sh matches these).
    static let prefixes = ["cedric-owl-test-", "cedric-ai-test-", "cedric-tests-", "cedric-default-", "cedric-bridge-", "cedric-accept-"]

    static let directory: String = {
        let d = (NSTemporaryDirectory() as NSString).appendingPathComponent("cedric-test-prefs")
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var suites: [String: InMemoryDefaults] = [:]

    /// The suite name (a path) for `prefix` + a UUID.
    static func name(_ prefix: String) -> String {
        precondition(prefixes.contains(prefix), "add \(prefix) to TestDefaults.prefixes and test.sh")
        return (directory as NSString).appendingPathComponent(prefix + UUID().uuidString)
    }

    /// The in-memory suite called `name`, made on first use; the same
    /// object every time until `remove(name)`.
    static func defaults(_ name: String) -> UserDefaults {
        lock.lock(); defer { lock.unlock() }
        if let d = suites[name] { return d }
        let d = InMemoryDefaults(suiteName: name)!
        suites[name] = d
        return d
    }

    /// A fresh suite and its name.
    static func make(_ prefix: String) -> (defaults: UserDefaults, name: String) {
        let n = name(prefix)
        return (defaults(n), n)
    }

    /// Forgets the suite and deletes its plist, should one exist.
    static func remove(_ name: String) {
        lock.lock(); suites[name] = nil; lock.unlock()
        try? FileManager.default.removeItem(atPath: name + ".plist")
    }
}

/// A UserDefaults that keeps its values in a dictionary in this process.
/// It overrides every primitive and typed accessor, with Foundation's
/// conversions (a number read as a string, "YES" read as a Bool, a path
/// read as a URL), so nothing reaches the superclass's real store. Values
/// are copied through a property list on the way in, as the real store
/// does, so a non-property-list value fails here too. The registration
/// domain (`register(defaults:)`) is answered when the suite has no value.
/// `didChangeNotification` is not posted.
final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    private let suite: String

    override init?(suiteName: String?) {
        suite = suiteName ?? ""
        super.init(suiteName: suiteName)
    }

    /// A property-list copy of `value` (as the real store keeps).
    private static func plistCopy(_ value: Any) -> Any {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: ["v": value], format: .binary, options: 0)
            let back = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            return (back as! [String: Any])["v"]!
        } catch {
            preconditionFailure("InMemoryDefaults: not a property list value: \(value) (\(error))")
        }
    }

    // MARK: Primitives

    override func object(forKey key: String) -> Any? {
        lock.lock(); defer { lock.unlock() }
        return values[key] ?? registered[key]
    }

    override func set(_ value: Any?, forKey key: String) {
        guard let value else { removeObject(forKey: key); return }
        let copy = Self.plistCopy(value)
        lock.lock(); values[key] = copy; lock.unlock()
    }

    override func removeObject(forKey key: String) {
        lock.lock(); values[key] = nil; lock.unlock()
    }

    override func register(defaults: [String: Any]) {
        let copy = defaults.mapValues(Self.plistCopy)
        lock.lock(); registered.merge(copy) { _, new in new }; lock.unlock()
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return registered.merging(values) { _, own in own }
    }

    override func persistentDomain(forName domainName: String) -> [String: Any]? {
        guard domainName == suite else { return nil }
        lock.lock(); defer { lock.unlock() }
        return values
    }

    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) {
        guard domainName == suite else { return }
        let copy = domain.mapValues(Self.plistCopy)
        lock.lock(); values = copy; lock.unlock()
    }

    override func removePersistentDomain(forName domainName: String) {
        guard domainName == suite else { return }
        lock.lock(); values = [:]; lock.unlock()
    }

    override func synchronize() -> Bool { true }

    override func objectIsForced(forKey key: String) -> Bool { false }
    override func objectIsForced(forKey key: String, inDomain domain: String) -> Bool { false }

    // MARK: Typed setters (the real ones store a property list too)

    override func set(_ value: Int, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Float, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Double, forKey key: String) { set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Bool, forKey key: String) { set(NSNumber(value: value), forKey: key) }

    override func set(_ url: URL?, forKey key: String) {
        guard let url else { removeObject(forKey: key); return }
        // Foundation keeps a file URL as a path (with ~) and archives others.
        if url.isFileURL {
            set((url.path as NSString).abbreviatingWithTildeInPath, forKey: key)
        } else {
            set(try? NSKeyedArchiver.archivedData(withRootObject: url, requiringSecureCoding: false), forKey: key)
        }
    }

    // MARK: Typed getters, with Foundation's conversions

    override func string(forKey key: String) -> String? {
        switch object(forKey: key) {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }

    override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }

    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }

    override func stringArray(forKey key: String) -> [String]? {
        guard let a = object(forKey: key) as? [Any] else { return nil }
        let s = a.compactMap { $0 as? String }
        return s.count == a.count ? s : nil
    }

    override func integer(forKey key: String) -> Int {
        switch object(forKey: key) {
        case let n as NSNumber: return n.intValue
        case let s as String: return (s as NSString).integerValue
        default: return 0
        }
    }

    override func float(forKey key: String) -> Float { Float(double(forKey: key)) }

    override func double(forKey key: String) -> Double {
        switch object(forKey: key) {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return (s as NSString).doubleValue
        default: return 0
        }
    }

    override func bool(forKey key: String) -> Bool {
        switch object(forKey: key) {
        case let n as NSNumber: return n.boolValue
        case let s as String: return (s as NSString).boolValue
        default: return false
        }
    }

    override func url(forKey key: String) -> URL? {
        switch object(forKey: key) {
        case let s as String: return URL(fileURLWithPath: (s as NSString).expandingTildeInPath)
        case let d as Data:
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: d) as URL?
        default: return nil
        }
    }
}
