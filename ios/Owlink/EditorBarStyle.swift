import UIKit
import CedricCore

/// How the navigation bar draws a theme.
///
/// The editor uses `navigationItem.style = .editor` with `documentProperties`,
/// so the file name is the document title (a menu), not the bar's plain
/// title label. On iOS 26/27 that title is drawn from the window scene: its
/// foreground comes from the scene's interface style and from the
/// navigation bar's tint. It ignores `titleTextAttributes` on the bar
/// instance. Setting only those attributes, or only the navigation
/// controller's interface style, leaves the name on the phone's label
/// colour — near-black on a dark theme while the phone is in light mode.
///
/// A fixed theme sets that bar tint and the scene's interface style. System
/// sets neither, so the phone's accent and appearance stay. The window's
/// own tint is left alone: painting it with the text colour replaces the
/// accent on sheets, alerts, toggles and Open Quickly.
///
/// Nothing here writes `UINavigationBar.appearance()`. That proxy is
/// process-wide: a detached preview never put it back, and one editor
/// dismissing cleared it under every other editor. Each window keeps its
/// own interface style, and dismissing an editor restores only that window.
enum EditorBarStyle {
    /// System follows the phone. A fixed theme forces its own light or dark.
    static func interfaceStyle(theme: EditorTheme, isDark: Bool) -> UIUserInterfaceStyle {
        theme == .system ? .unspecified : (isDark ? .dark : .light)
    }

    /// What a scene's window shows where nothing covers it: the system
    /// background, white in light mode and black in dark, following the
    /// window's (the phone's) appearance. A window's own default is no
    /// colour, which draws black: closing an editor in light mode showed
    /// black for a moment before the document browser drew.
    static let windowBackground: UIColor = .systemBackground

    /// One appearance, shared by the bar and the navigation item.
    static func appearance(foreground: UIColor) -> UINavigationBarAppearance {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        let title: [NSAttributedString.Key: Any] = [.foregroundColor: foreground]
        appearance.titleTextAttributes = title
        appearance.largeTitleTextAttributes = title
        if #available(iOS 26.0, *) {
            appearance.subtitleTextAttributes = title
            appearance.largeSubtitleTextAttributes = title
        }
        return appearance
    }

    static func apply(navigationController: UINavigationController?,
                      item: UINavigationItem,
                      window: UIWindow?,
                      foreground: UIColor,
                      interfaceStyle: UIUserInterfaceStyle) {
        let appearance = appearance(foreground: foreground)
        let titleAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: foreground]
        // System (.unspecified) follows the phone. A fixed theme forces its
        // light or dark, and tints the bar — not the window — with the text colour.
        let fixed = interfaceStyle != .unspecified
        if let bar = navigationController?.navigationBar {
            bar.standardAppearance = appearance
            bar.compactAppearance = appearance
            bar.scrollEdgeAppearance = appearance
            bar.compactScrollEdgeAppearance = appearance
            bar.titleTextAttributes = titleAttributes
            bar.tintColor = fixed ? foreground : nil
            bar.overrideUserInterfaceStyle = interfaceStyle
        }
        item.standardAppearance = appearance
        item.compactAppearance = appearance
        item.scrollEdgeAppearance = appearance
        item.compactScrollEdgeAppearance = appearance
        // iOS 26 draws `attributedTitle` (and ignores it when a title view
        // is set; the editor does not set one). The document title still
        // follows the bar tint and the scene style, which is why those are set.
        if #available(iOS 26.0, *) {
            item.attributedTitle = colored(item.title, foreground)
            item.attributedSubtitle = colored(item.subtitle, foreground)
        }
        if let nav = navigationController {
            // A tint on the controller's view reaches every control in it.
            if nav.view.tintColor != nil { nav.view.tintColor = nil }
            if nav.overrideUserInterfaceStyle != interfaceStyle {
                nav.overrideUserInterfaceStyle = interfaceStyle
                nav.setNeedsStatusBarAppearanceUpdate()
            }
        }
        guard let window else { return }
        if window.tintColor != nil { window.tintColor = nil }
        if window.overrideUserInterfaceStyle != interfaceStyle {
            window.overrideUserInterfaceStyle = interfaceStyle
        }
        window.traitOverrides.userInterfaceStyle = interfaceStyle
        window.windowScene?.traitOverrides.userInterfaceStyle = interfaceStyle
    }

    /// Puts this window back on the phone's style as its editor goes: at
    /// the start of the close, before the browser is uncovered (see
    /// `EditorViewController.handWindowBackToPhone`). Other windows are
    /// left as they are. A detached preview has no call: its window goes
    /// away with the scene, and there is no shared proxy to put back.
    static func restore(window: UIWindow?) {
        window?.tintColor = nil
        window?.overrideUserInterfaceStyle = .unspecified
        window?.traitOverrides.userInterfaceStyle = .unspecified
        window?.windowScene?.traitOverrides.userInterfaceStyle = .unspecified
    }

    /// Draws `view` (the editor's navigation bar) to a PNG. `-OwlinkNavBarPNG
    /// <path>` on a debug launch asks for this; the self-check writes one
    /// beside each window shot.
    static func renderNavigationBar(_ view: UIView, to url: URL) {
        view.layoutIfNeeded()
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.traitCollection.displayScale > 0 ? view.traitCollection.displayScale : 2
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? image.pngData()?.write(to: url)
    }

    static func renderNavigationBarIfRequested(_ view: UIView?) {
        guard let view else { return }
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-OwlinkNavBarPNG"), i + 1 < args.count else { return }
        renderNavigationBar(view, to: URL(fileURLWithPath: args[i + 1]))
    }

    @available(iOS 26.0, *)
    private static func colored(_ text: String?, _ foreground: UIColor) -> AttributedString? {
        guard let text, !text.isEmpty else { return nil }
        var styled = AttributedString(text)
        styled.uiKit.foregroundColor = foreground
        return styled
    }
}
