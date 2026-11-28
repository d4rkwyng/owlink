import Foundation

/// Tests only: counts what the line parsers (`WikiLinks`, `Tags`) produce
/// and the work `TagTree` does, inside `ParseCounter.$current.withValue`.
/// Nil (nothing counted) everywhere else.
public final class ParseCounter: @unchecked Sendable {
    /// Links and tags the line parsers made (before any limit or dedupe).
    public var produced = 0
    /// Tag tree entries expanded and nodes built.
    public var treeWork = 0

    public init() {}

    @TaskLocal public static var current: ParseCounter?
}
