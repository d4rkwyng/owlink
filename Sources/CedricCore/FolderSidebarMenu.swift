import Foundation

/// The folder sidebar header menu, independent of AppKit.
public enum FolderSidebarMenu {
    public enum Command: String, CaseIterable, Equatable, Sendable {
        case newFile
        case newFolder
        case rename
        case moveToTrash
        case revealInFinder
        case openEnclosingFolder
        case copyPath
        case findInFolder
        case refresh
        case collapseAll
        case showHiddenFiles
        case openFolder
        case closeFolder
    }

    public enum Selection: Equatable, Sendable {
        case none
        case file(parentIsRoot: Bool)
        case folder
    }

    public enum Item: Equatable, Sendable {
        case separator
        case command(Command, isEnabled: Bool, isChecked: Bool? = nil)
    }

    public struct State: Equatable, Sendable {
        public var selection: Selection
        public var anyExpanded: Bool
        public var showHidden: Bool

        public init(selection: Selection, anyExpanded: Bool, showHidden: Bool) {
            self.selection = selection
            self.anyExpanded = anyExpanded
            self.showHidden = showHidden
        }
    }

    public static func items(for state: State) -> [Item] {
        let hasSelection = state.selection != .none
        let canOpenEnclosing: Bool
        if case .file(parentIsRoot: false) = state.selection {
            canOpenEnclosing = true
        } else {
            canOpenEnclosing = false
        }

        return [
            .command(.newFile, isEnabled: true),
            .command(.newFolder, isEnabled: true),
            .separator,
            .command(.rename, isEnabled: hasSelection),
            .command(.moveToTrash, isEnabled: hasSelection),
            .separator,
            .command(.revealInFinder, isEnabled: true),
            .command(.openEnclosingFolder, isEnabled: canOpenEnclosing),
            .command(.copyPath, isEnabled: true),
            .command(.findInFolder, isEnabled: true),
            .separator,
            .command(.refresh, isEnabled: true),
            .command(.collapseAll, isEnabled: state.anyExpanded),
            .separator,
            .command(.showHiddenFiles, isEnabled: true, isChecked: state.showHidden),
            .separator,
            .command(.openFolder, isEnabled: true),
            .separator,
            .command(.closeFolder, isEnabled: true),
        ]
    }
}
