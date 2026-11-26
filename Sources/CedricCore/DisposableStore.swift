import Foundation

/// Check builds launched by a destructive check (crash-check kills the
/// app, edits and truncates its store): `CEDRIC_DISPOSABLE_STORE` is the
/// filesystem identity ("device:inode") of the throwaway session folder
/// the script made, and the app refuses to start unless its session
/// folder is that very folder. The script's own checks run before the
/// launch; this one runs in the process that will write, on the folder
/// it will write, so a path retargeted in between (a link, a renamed
/// ancestor) or a different binary's idea of the session can't slip by.
/// Identities, not path strings: a case-insensitive volume has many
/// spellings of one folder.
public enum DisposableStore {
    /// "device:inode" of `path` itself (not followed if it is a link), or nil.
    public static func identity(_ path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return "\(st.st_dev):\(st.st_ino)"
    }

    /// Nil when `dir` is a real folder (not a link), this user's own, with
    /// identity `expected`, and neither it nor any folder above it is one
    /// of `protected` (nor is any of them inside it). Else why not.
    public static func refusal(_ dir: URL, expected: String, protected: [URL]) -> String? {
        let path = dir.path
        var st = stat()
        guard lstat(path, &st) == 0 else { return "\(path) is missing" }
        guard st.st_mode & S_IFMT == S_IFDIR else { return "\(path) is a link or not a folder" }
        guard st.st_uid == getuid() else { return "\(path) isn't this user's" }
        guard let id = identity(path), id == expected else { return "\(path) is \(identity(path) ?? "-"), not the folder \(expected)" }
        let guarded = Set(protected.compactMap { identity($0.path) })
        // Up from the folder, through the real (resolved) path.
        var p = (path as NSString).resolvingSymlinksInPath
        while true {
            if let i = identity(p), guarded.contains(i) { return "\(path) is in the real session folder (\(p))" }
            if p == "/" || p.isEmpty { break }
            p = (p as NSString).deletingLastPathComponent
        }
        // And up from each protected folder: none of them is inside it.
        for q in protected {
            var p = (q.path as NSString).resolvingSymlinksInPath
            while p != "/", !p.isEmpty {
                if identity(p) == id { return "\(path) holds the real session folder \(q.path)" }
                p = (p as NSString).deletingLastPathComponent
            }
        }
        return nil
    }
}
