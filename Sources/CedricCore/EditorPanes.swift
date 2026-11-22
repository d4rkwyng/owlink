import Foundation
import CoreGraphics

/// Which panes the iOS editor shows: the text, the Markdown preview and
/// Ask Cedric, by width. A phone-sized width (compact) shows one pane and
/// Ask Cedric as a sheet; a wide one (an iPad, an unfolded iPhone Duo) at
/// most two panes: never three columns. Ask Cedric on a wide screen is
/// always the side panel, and it takes the preview's place (the preview
/// comes back when it closes). Focus Preview is the preview alone.
public enum EditorPanes {
    public enum Ask: Equatable, Sendable { case none, panel, sheet }

    public struct Layout: Equatable, Sendable {
        public var text: Bool
        public var preview: Bool
        public var ask: Ask
        public var focus: Bool

        public init(text: Bool, preview: Bool, ask: Ask, focus: Bool = false) {
            self.text = text
            self.preview = preview
            self.ask = ask
            self.focus = focus
        }

        /// The columns side by side (the sheet floats over, not a column).
        public var columns: Int { (text ? 1 : 0) + (preview ? 1 : 0) + (ask == .panel ? 1 : 0) }
    }

    /// `askOpen`: Ask Cedric is open (panel or sheet). Opening it leaves
    /// Focus Preview (the editor asks about the text; see `askOpens`).
    public static func layout(previewOn: Bool, askOpen: Bool, focus: Bool, regularWidth: Bool) -> Layout {
        let focus = focus && previewOn && !askOpen
        if focus { return Layout(text: false, preview: true, ask: .none, focus: true) }
        if regularWidth {
            if askOpen { return Layout(text: true, preview: false, ask: .panel) }
            return Layout(text: true, preview: previewOn, ask: .none)
        }
        return Layout(text: !previewOn, preview: previewOn, ask: askOpen ? .sheet : .none)
    }

    /// How Ask Cedric is shown at a width: a wide screen always gets the
    /// panel (a sheet left over from a folded phone becomes the panel when
    /// it opens), a compact one the sheet.
    public static func askPresentation(regularWidth: Bool) -> Ask { regularWidth ? .panel : .sheet }

    /// Ask Cedric is shown as `current` and the width is now `regularWidth`:
    /// the presentation to switch to, or nil to keep it.
    public static func askSwitch(from current: Ask, regularWidth: Bool) -> Ask? {
        guard current != .none else { return nil }
        let want = askPresentation(regularWidth: regularWidth)
        return want == current ? nil : want
    }

    /// Where the owl may sit: the text pane, less anything a chat panel
    /// covers (the side of the text pane away from it). Empty: hide him.
    public static func owlArea(textPane: CGRect, chat: CGRect?, minSize: CGFloat = 0) -> CGRect {
        var area = textPane
        if let c = chat, !c.isEmpty, c.intersects(area) {
            if c.midX >= area.midX {
                area.size.width = max(0, c.minX - area.minX)
            } else {
                let x = min(area.maxX, c.maxX)
                area = CGRect(x: x, y: area.minY, width: max(0, area.maxX - x), height: area.height)
            }
        }
        guard area.width >= minSize, area.height >= minSize, area.width > 0, area.height > 0 else { return .zero }
        return area
    }

    /// The owl is shown only where he can't cover the chat or Focus Preview.
    public static func owlHidden(layout: Layout, owlFrame: CGRect, chat: CGRect?) -> Bool {
        if layout.focus || !layout.text { return layout.focus }
        guard let c = chat, !c.isEmpty else { return false }
        return owlFrame.intersects(c)
    }

    /// Where the status bar's bottom edge sits, in the editor view (y down).
    ///
    /// With the keyboard hidden or floating, the bar rests at the screen edge.
    /// A docked keyboard lifts it to the keyboard's top.
    public static func statusBarBottom(viewHeight: CGFloat, keyboardTop: CGFloat, keyboardBottom: CGFloat, homeInset: CGFloat) -> CGFloat {
        guard viewHeight > 0 else { return 0 }
        let homeInset = max(homeInset, 0)
        let coversBottom = keyboardBottom >= viewHeight - 1 && keyboardTop <= viewHeight - 1
        let gap = viewHeight - keyboardTop
        if !coversBottom || gap <= homeInset + 80 { return viewHeight }
        return keyboardTop
    }

    /// Height of the status bar: fill the home-indicator zone up to a 34 pt
    /// cap, and stay a 24 pt readable strip when the inset is smaller or a
    /// keyboard is up.
    public static func statusBarHeight(homeInset: CGFloat) -> CGFloat {
        min(max(max(homeInset, 0), 24), 34)
    }
}
