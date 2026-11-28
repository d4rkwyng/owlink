import Foundation

/// Reading a file into a tab (open, reopen, Reload, an encoding reopen,
/// Follow File's catch-up): its bytes into memory of their own, decoded,
/// and the stamp of the file those bytes came from.
public enum DocumentRead {
    public enum LoadError: Error, LocalizedError {
        case unreadable(URL, Error)
        case notText(URL)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let u, let e): return String(localized: "Couldn’t open “\(u.lastPathComponent)”: \(e.localizedDescription)")
            case .notText(let u): return String(localized: "“\(u.lastPathComponent)” isn’t text in a supported encoding.")
            }
        }
    }

    /// Reads and decodes a file; returns the LF-normalised text and the
    /// file's stamp. The stamp comes from the descriptor the bytes are
    /// read from (`fstat` just before the read, TextCodec.snapshotStamped):
    /// taken from the path, a link pointed elsewhere or a file replaced in
    /// between gave the stamp of one file with the bytes of another, and
    /// ⌘S then trusted it. A file changed after the stamp, while it is
    /// read, still shows as a change at the next check.
    /// The bytes are always read into memory of their own (not mapped),
    /// so the file changing meanwhile changes nothing already read.
    /// `shareBytes`: a large ASCII file's text reads them in place
    /// (TextCodec.decode), for opening into a tab. `hooks`: tests only.
    /// `encoding`: the tab's (nil: detected); read as its base
    /// (TextEncoding.base), so whether there is a UTF-8 BOM is up to the
    /// bytes read now, never to the version the tab read before: open,
    /// Reload, Revert to Saved, an encoding reopen, a restored or reopened
    /// tab all read whichever version is on disk now.
    public static func read(_ url: URL, encoding: TextEncoding? = nil, shareBytes: Bool = false,
                            hooks: TextCodec.ReadHooks? = nil, forOpen: Bool = false) throws -> (DecodedText, DiskStamp?) {
        if let kind = SpecialFile.kind(atPath: url.path) {
            throw LoadError.unreadable(url, NSError(domain: "Cedric", code: 2, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "It is \(kind), not a regular file.")]))
        }
        let read: (text: DecodedText?, stamp: DiskStamp)
        do {
            read = try TextCodec.readTextStamped(at: url, as: encoding?.base, shareBytes: shareBytes, hooks: hooks,
                                                 forOpen: forOpen && encoding == nil)
        } catch {
            throw LoadError.unreadable(url, error)
        }
        guard let decoded = read.text else { throw LoadError.notText(url) }
        return (decoded, read.stamp)
    }
}
