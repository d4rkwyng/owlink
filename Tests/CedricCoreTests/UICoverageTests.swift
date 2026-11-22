import Foundation
import Testing

@Suite struct UICoverageTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func userFacingStringsUseLocalization() throws {
        let patterns: [(String, String)] = [
            ("placeholderString", #"\bplaceholderString\s*=\s*("(?:\\.|[^"\\])*")"#),
            ("messageText", #"\bmessageText\s*=\s*("(?:\\.|[^"\\])*")"#),
            ("informativeText", #"\binformativeText\s*=\s*("(?:\\.|[^"\\])*")"#),
            ("toolTip", #"\btoolTip\s*=\s*("(?:\\.|[^"\\])*")"#),
            ("labelWithString", #"\blabelWithString:\s*("(?:\\.|[^"\\])*")"#),
            ("checkboxWithTitle", #"\bcheckboxWithTitle:\s*("(?:\\.|[^"\\])*")"#),
            ("radioButtonWithTitle", #"\bradioButtonWithTitle:\s*("(?:\\.|[^"\\])*")"#),
            ("addButton", #"\baddButton\(withTitle:\s*("(?:\\.|[^"\\])*")"#),
            ("menuItemTitle", #"\bNSMenuItem\(title:\s*("(?:\\.|[^"\\])*")"#),
            ("buttonTitle", #"\bNSButton\(title:\s*("(?:\\.|[^"\\])*")"#),
            ("accessibilityDescription", #"\baccessibilityDescription:\s*("(?:\\.|[^"\\])*")"#),
            ("accessibilityLabel", #"\bsetAccessibilityLabel\(\s*("(?:\\.|[^"\\])*")"#),
            ("prompt", #"\bprompt\s*=\s*("(?:\\.|[^"\\])*")"#),
            ("windowTitle", #"\b(?:window|panel)\.title\s*=\s*("(?:\\.|[^"\\])*")"#),
        ]
        let compiled = try patterns.map { ($0.0, try NSRegularExpression(pattern: $0.1)) }
        let sourceRoot = Self.root.appendingPathComponent("Sources", isDirectory: true)
        guard let files = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var violations: [String] = []

        while let file = files.nextObject() as? URL {
            guard file.pathExtension == "swift",
                  !file.lastPathComponent.hasSuffix("Check.swift"),
                  file.lastPathComponent != "DevChecks.swift" else { continue }
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (lineIndex, line) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                for (api, regex) in compiled {
                    for match in regex.matches(in: text, range: range) {
                        guard let literalRange = Range(match.range(at: 1), in: text) else { continue }
                        let literal = String(text[literalRange])
                        let value = String(literal.dropFirst().dropLast())
                        // Empty AppKit titles are deliberate; numeric page fields, the documented
                        // example server URL, and path-only tooltips carry no translatable language.
                        if value.isEmpty { continue }
                        if api == "placeholderString",
                           value.range(of: #"^\d+(?::\d+)?$"#, options: .regularExpression) != nil { continue }
                        if api == "placeholderString", value == #"\(min(2, doc.pageCount))"# { continue }
                        if api == "placeholderString", value == "http://studio.local:1234/v1" { continue }
                        if api == "toolTip",
                           value.hasPrefix("/")
                            || value.range(of: #"^\\\([A-Za-z_][A-Za-z0-9_.]*\.path\)$"#, options: .regularExpression) != nil { continue }
                        let relative = file.path.replacingOccurrences(of: Self.root.path + "/", with: "")
                        violations.append("\(relative):\(lineIndex + 1): \(text.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }

        #expect(violations.isEmpty)
    }

    @Test func keyControlsHaveAccessibilityLabels() throws {
        let folder = try Self.source("Sources/CedricApp/FolderSidebar.swift")
        #expect(folder.contains("close.setAccessibilityLabel(String(localized: \"Close Folder\"))"))
        #expect(folder.contains("outline.setAccessibilityLabel(String(localized: \"Folder\"))"))

        let chat = try Self.source("Sources/CedricApp/Owl/OwlChatPanel.swift")
        #expect(chat.contains("scopePopup.setAccessibilityLabel(String(localized: \"Asking about\"))"))
        #expect(chat.contains("input.setAccessibilityLabel(String(localized: \"Question for Cedric\"))"))

        let bars = try Self.source("Sources/CedricApp/Bars.swift")
        #expect(bars.contains("findField.setAccessibilityLabel(String(localized: \"Find\"))"))
        #expect(bars.contains("replaceField.setAccessibilityLabel(String(localized: \"Replace\"))"))
        #expect(bars.contains(#"let prev = chevron("chevron.left", String(localized: "Find Previous")"#))
        #expect(bars.contains(#"let next = chevron("chevron.right", String(localized: "Find Next")"#))
        #expect(bars.contains("String(localized: \"Language\")"))
        #expect(bars.contains("String(localized: \"Text Encoding\")"))
        #expect(bars.contains("String(localized: \"Line Endings\")"))
        #expect(bars.contains("b.setAccessibilityLabel(label)"))

        let git = try Self.source("Sources/CedricApp/GitIntegration.swift")
        #expect(git.contains("b.setAccessibilityLabel(label +"))

        let contextBar = try Self.source("Sources/CedricApp/ContextBar.swift")
        #expect(contextBar.contains("b.setAccessibilityLabel(label)"))
        #expect(contextBar.contains("p.setAccessibilityLabel(label)"))

        let settings = try Self.source("Sources/CedricApp/SettingsWindow.swift")
        #expect(settings.contains("control.setAccessibilityLabel(spoken ??"))
        #expect(settings.contains("fontStepper.setAccessibilityLabel("))
        #expect(settings.contains("accessibilityDescription: item.label"))
        let aiSettings = try Self.source("Sources/CedricApp/Owl/OwlAISettings.swift")
        #expect(aiSettings.contains("control.setAccessibilityLabel("))
        let editCard = try Self.source("Sources/CedricApp/Owl/OwlEditCard.swift")
        #expect(editCard.contains("diffView.setAccessibilityLabel(String(localized: \"Before and after\"))"))
        let owl = try Self.source("Sources/CedricApp/Owl/OwlView.swift")
        #expect(owl.contains("setAccessibilityLabel(String(localized: \"Cedric the owl\"))"))

        let goToLine = try Self.source("Sources/CedricApp/EditorWindowController.swift")
        #expect(goToLine.contains("field.setAccessibilityLabel(String(localized: \"Line number or line:column\"))"))
    }
}
