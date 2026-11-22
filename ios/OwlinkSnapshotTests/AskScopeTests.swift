import XCTest
import CedricCore
import CedricAI

@MainActor
final class AskScopeTests: XCTestCase {
    func testDefaultsAndPickedScopeFollowSelection() throws {
        var selection = NSRange(location: 0, length: 0)
        let model = AskCedricModel(fileName: nil, language: .plain)
        model.makeSnapshot = {
            OwlDocumentSnapshot(text: "first\nsecond\nthird", generation: 0, selection: selection,
                                visible: NSRange(location: 6, length: 6))
        }

        model.refreshScope()
        XCTAssertEqual(model.scope, .wholeDocument)
        XCTAssertEqual(model.scopes, [.visible, .wholeDocument])
        selection = NSRange(location: 0, length: 5)
        model.refreshScope()
        XCTAssertEqual(model.scope, .selection)
        model.selectScope(.visible)
        let visibleContext = try XCTUnwrap(OwlChatRequest.documentContext(model.makeSnapshot(), scope: .visible,
                                                                          engineBudget: model.contextBudget, history: [],
                                                                          question: "", action: nil, tools: false,
                                                                          server: false, prose: true, preview: true))
        XCTAssertEqual(model.scopeLabel, visibleContext.label)
        selection = NSRange(location: 0, length: 0)
        model.refreshScope()
        XCTAssertEqual(model.scope, .visible)
        selection = NSRange(location: 0, length: 5)
        model.refreshScope()
        XCTAssertEqual(model.scope, .visible)
        model.selectScope(.selection)
        selection = NSRange(location: 0, length: 0)
        model.refreshScope()
        XCTAssertEqual(model.scope, .wholeDocument)
        selection = NSRange(location: 0, length: 5)
        model.refreshScope()
        XCTAssertEqual(model.scope, .selection)
    }

    func testLabelTracksVisibleRangeAndUsesQuestionIndependentPreview() throws {
        let text = (1...900).map { "Line \($0): some text in this document" }.joined(separator: "\n")
        var visible = NSRange(location: 0, length: 10)
        let model = AskCedricModel(fileName: nil, language: .plain)
        model.makeSnapshot = { OwlDocumentSnapshot(text: text, generation: 0, visible: visible) }
        model.question = "What does this document say?"
        model.refreshScope()
        let snap = model.makeSnapshot()
        let expected = try XCTUnwrap(OwlChatRequest.documentContext(snap, scope: .wholeDocument, engineBudget: model.contextBudget,
                                                                    history: [], question: "", action: nil,
                                                                    tools: false, server: false, prose: true, preview: true))
        XCTAssertEqual(model.scopeLabel, expected.label)
        model.question = String(repeating: "another question ", count: 100)
        model.refreshScope()
        XCTAssertEqual(model.scopeLabel, expected.label)
        model.selectScope(.visible)
        let first = model.scopeLabel
        visible = (text as NSString).range(of: "Line 10:")
        model.refreshScope()
        XCTAssertEqual(model.scopeLabel, first)
        XCTAssertEqual(model.scope, .visible)
        visible.length = 100
        model.refreshScope()
        XCTAssertNotEqual(model.scopeLabel, first)
    }

    func testEditorRefreshesAreCoalescedAndRequireVisibility() async throws {
        var visible = true
        var snapshots = 0
        let model = AskCedricModel(fileName: nil, language: .plain)
        model.askIsVisible = { visible }
        model.makeSnapshot = {
            snapshots += 1
            return OwlDocumentSnapshot(text: "first\nsecond", generation: 0)
        }
        model.scheduleScopeRefresh()
        model.scheduleScopeRefresh()
        model.scheduleScopeRefresh()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(snapshots, 1)

        model.scheduleScopeRefresh()
        visible = false
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(snapshots, 1)
        model.scheduleScopeRefresh()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(snapshots, 1)
    }
}
