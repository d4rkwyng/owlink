import XCTest

/// Owlink's base language is US English: the copy people see (localized
/// strings, SwiftUI Text/Button/Label titles, accessibility labels and
/// hints) never uses the British -ise/-our/-re spellings. Checked in the
/// sources, like LocalizedCopyTests: the iOS app and the shared
/// CedricCore/CedricAI layers it shows text from.
final class USEnglishCopyTests: XCTestCase {
    /// Stems that are British only (US: summarize, color, center, license…).
    static let british = #"(?i)\b\w*(summaris|organis|customis|recognis|optimis|initialis|normalis|authoris|synchronis|categoris|visualis|prioritis|standardis|minimis|maximis|emphasis(e|ing)|apologis|colour|behaviour|favourit|honour|neighbour|catalogue|cancell(ed|ing)|labell(ed|ing)|centre|licence)\w*"#
    /// A user-facing string literal: its call, then the literal's text.
    static let userFacing = #"(?:String\(localized:|Text\(|Button\(|Label\(|Toggle\(|Section\(|\.navigationTitle\(|\.alert\(|accessibilityLabel(?:\s*=|\()|accessibilityHint(?:\s*=|\()|title:|message:)\s*"((?:[^"\\]|\\.)*)""#

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    static func offenders(in source: String) -> [String] {
        let strings = try! NSRegularExpression(pattern: userFacing)
        let words = try! NSRegularExpression(pattern: british)
        var found: [String] = []
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            let ns = line as NSString
            for m in strings.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let text = ns.substring(with: m.range(at: 1))
                let t = text as NSString
                for w in words.matches(in: text, range: NSRange(location: 0, length: t.length)) {
                    found.append("\(t.substring(with: w.range)) in “\(text)”")
                }
            }
        }
        return found
    }

    private func swiftFiles(_ dir: URL) -> [URL] {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    func testTheScanCatchesBritishSpellings() {
        XCTAssertEqual(Self.offenders(in: #"case .summarise: return String(localized: "Summarise")"#).count, 1)
        XCTAssertEqual(Self.offenders(in: #"Text(String(localized: "Pick a colour"))"#).count, 1)
        XCTAssertEqual(Self.offenders(in: #"a.accessibilityLabel = "Centre the text""#).count, 1)
        // Identifiers and comments are not copy.
        XCTAssertTrue(Self.offenders(in: #".accessibilityIdentifier("licence.text")"#).isEmpty)
        XCTAssertTrue(Self.offenders(in: #"// colour the tab"#).isEmpty)
        XCTAssertTrue(Self.offenders(in: #"Text(String(localized: "Summarize"))"#).isEmpty)
    }

    func testUserFacingCopyIsUSEnglish() throws {
        let repo = root.deletingLastPathComponent()
        let dirs = [root.appendingPathComponent("Owlink"),
                    repo.appendingPathComponent("Sources/CedricCore"),
                    repo.appendingPathComponent("Sources/CedricAI")]
        var all: [String] = []
        for dir in dirs {
            let files = swiftFiles(dir)
            XCTAssertFalse(files.isEmpty, "no sources under \(dir.path)")
            for f in files {
                let text = try String(contentsOf: f, encoding: .utf8)
                all += Self.offenders(in: text).map { "\(f.lastPathComponent): \($0)" }
            }
        }
        XCTAssertEqual(all, [], "British spellings in user-facing copy")
    }
}
