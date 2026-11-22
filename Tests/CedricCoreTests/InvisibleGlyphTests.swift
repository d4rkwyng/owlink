import Testing
@testable import CedricCore

@Suite struct InvisibleGlyphTests {
    @Test func macWhitespaceGlyphs() {
        #expect(InvisibleGlyph.forUTF16(32) == "·")
        #expect(InvisibleGlyph.forUTF16(9) == "→")
        #expect(InvisibleGlyph.forUTF16(10) == "¬")
        #expect(InvisibleGlyph.forUTF16(13) == nil)
        #expect(InvisibleGlyph.forUTF16(0x00a0) == nil)
        #expect(InvisibleGlyph.forUTF16(65) == nil)
    }
}
