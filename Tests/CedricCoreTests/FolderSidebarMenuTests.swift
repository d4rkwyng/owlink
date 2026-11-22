import Foundation
import Testing
@testable import CedricCore

@Suite struct FolderSidebarMenuTests {
    private let expectedOrder: [FolderSidebarMenu.Item] = [
        .command(.newFile, isEnabled: true),
        .command(.newFolder, isEnabled: true),
        .separator,
        .command(.rename, isEnabled: false),
        .command(.moveToTrash, isEnabled: false),
        .separator,
        .command(.revealInFinder, isEnabled: true),
        .command(.openEnclosingFolder, isEnabled: false),
        .command(.copyPath, isEnabled: true),
        .command(.findInFolder, isEnabled: true),
        .separator,
        .command(.refresh, isEnabled: true),
        .command(.collapseAll, isEnabled: false),
        .separator,
        .command(.showHiddenFiles, isEnabled: true, isChecked: false),
        .separator,
        .command(.openFolder, isEnabled: true),
        .separator,
        .command(.closeFolder, isEnabled: true),
    ]

    private func item(_ items: [FolderSidebarMenu.Item], _ command: FolderSidebarMenu.Command) -> FolderSidebarMenu.Item? {
        items.first {
            if case .command(let c, _, _) = $0 { return c == command }
            return false
        }
    }

    @Test func itemOrderSeparatorsAndNoSelectionEnablement() {
        let items = FolderSidebarMenu.items(for: .init(selection: .none, anyExpanded: false, showHidden: false))
        #expect(items == expectedOrder)

        let expanded = FolderSidebarMenu.items(for: .init(selection: .none, anyExpanded: true, showHidden: false))
        #expect(item(expanded, .collapseAll) == .command(.collapseAll, isEnabled: true))
    }

    @Test func enclosingFolderDependsOnSelectedFileLocation() {
        let subfolderFile = FolderSidebarMenu.items(for: .init(selection: .file(parentIsRoot: false), anyExpanded: false, showHidden: false))
        #expect(item(subfolderFile, .openEnclosingFolder) == .command(.openEnclosingFolder, isEnabled: true))

        let rootFile = FolderSidebarMenu.items(for: .init(selection: .file(parentIsRoot: true), anyExpanded: false, showHidden: false))
        #expect(item(rootFile, .openEnclosingFolder) == .command(.openEnclosingFolder, isEnabled: false))
    }

    @Test func folderSelectionEnablesRenameAndTrashOnly() {
        let items = FolderSidebarMenu.items(for: .init(selection: .folder, anyExpanded: false, showHidden: false))
        #expect(item(items, .rename) == .command(.rename, isEnabled: true))
        #expect(item(items, .moveToTrash) == .command(.moveToTrash, isEnabled: true))
        #expect(item(items, .openEnclosingFolder) == .command(.openEnclosingFolder, isEnabled: false))
    }

    @Test func hiddenFilesCheckboxReflectsState() {
        let on = FolderSidebarMenu.items(for: .init(selection: .none, anyExpanded: false, showHidden: true))
        #expect(item(on, .showHiddenFiles) == .command(.showHiddenFiles, isEnabled: true, isChecked: true))
        let off = FolderSidebarMenu.items(for: .init(selection: .none, anyExpanded: false, showHidden: false))
        #expect(item(off, .showHiddenFiles) == .command(.showHiddenFiles, isEnabled: true, isChecked: false))
    }
}
