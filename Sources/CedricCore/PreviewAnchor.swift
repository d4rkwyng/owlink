import Foundation

/// A heading a preview link points at (`other.md#part`, `#part`,
/// `[[other#Part]]`). The fragment travels with the local document
/// through the preview's history, and after the page has loaded the
/// preview scrolls to the first element whose `id` (or `name`) is one of
/// `candidates`: the fragment as written, then its heading slug (so
/// `#Part` or `#The Part` find `## The Part`, `id="the-part"`).
public enum PreviewAnchor {
    /// `url`'s fragment, percent-decoded; nil when there is none or it is empty.
    public static func fragment(of url: URL) -> String? {
        guard let f = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment, !f.isEmpty else { return nil }
        return f
    }

    /// The ids to look for, best first: the exact fragment, then the slug
    /// Markdown gives a heading of that text (when different and not empty).
    public static func candidates(for fragment: String) -> [String] {
        guard !fragment.isEmpty else { return [] }
        var out = [fragment]
        let slug = headingID(fragment)
        if !slug.isEmpty, slug != fragment { out.append(slug) }
        return out
    }

    /// The id the Markdown preview gives the first heading with this text.
    public static func headingID(_ text: String) -> String { Markdown.slug(text) }
}
