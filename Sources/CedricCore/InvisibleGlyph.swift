/// The editor's visible substitutes for whitespace, without changing text.
public enum InvisibleGlyph {
    public static func forUTF16(_ unit: UInt16) -> String? {
        switch unit {
        case 32: return "·"
        case 9: return "→"
        case 10: return "¬"
        default: return nil
        }
    }
}
