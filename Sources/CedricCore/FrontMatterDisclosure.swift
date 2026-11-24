import Foundation

/// The preview's front matter block (`<details class="frontmatter">`, see
/// `Markdown.Options.frontMatterExpanded`) as the reader leaves it, on the
/// Mac and iOS alike: whether a page's block is open, setting it in a page
/// about to be loaded, and when a state read from a page is the reader's
/// own change to keep as the preference.
public enum FrontMatterDisclosure {
    /// Where the block starts in rendered HTML (keys and values are
    /// escaped, so only the renderer writes this).
    public static let opening = "<details class=\"frontmatter\""

    /// The preference's key (UserDefaults), the same on both platforms.
    public static let preferenceKey = "previewFrontMatterExpanded"

    /// Whether the front matter block in `html` is open; nil without one.
    public static func isOpen(in html: String) -> Bool? {
        guard let attributes = attributesRange(in: html) else { return nil }
        return html[attributes].contains(" open")
    }

    /// `html` with its front matter block open or closed (unchanged
    /// without one).
    public static func setting(open: Bool, in html: String) -> String {
        guard let attributes = attributesRange(in: html) else { return html }
        var kept = html[attributes].replacingOccurrences(of: " open", with: "")
        if open { kept += " open" }
        return html.replacingCharacters(in: attributes, with: kept)
    }

    private static func attributesRange(in html: String) -> Range<String.Index>? {
        guard let start = html.range(of: opening),
              let end = html[start.upperBound...].firstIndex(of: ">") else { return nil }
        return start.upperBound..<end
    }

    /// The reader's change to keep, if any: the block's state as read
    /// (`read`, nil without a block) when it differs from the state that
    /// page last had from the app (`applied`) and that page (`readFor`) is
    /// still the one shown (`shown`). An untouched page, or a read that
    /// comes back after its page was replaced, keeps nothing.
    public static func change(read: Bool?, applied: Bool?, readFor: Int, shown: Int?) -> Bool? {
        guard let read, let applied, readFor == shown, read != applied else { return nil }
        return read
    }
}
