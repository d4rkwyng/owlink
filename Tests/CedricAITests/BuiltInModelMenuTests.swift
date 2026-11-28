import Foundation
import Testing
@testable import CedricAI

/// Settings › Cedric's compact Model popup: each catalog model's title and
/// tag, and the Automatic item, without AppKit.
@Suite struct BuiltInModelMenuTests {
    private func model(name: String = "Qwen Test 3B", license: String = "Apache-2.0", size: Int64 = 2_104_932_800,
                       isDefault: Bool = false) -> BuiltInModel {
        var m = testModel(id: "menu-test", body: Data("x".utf8), size: size, isDefault: isDefault)
        m.name = name
        m.summary = "Good code hints."
        m.license = license
        m.minRAMGB = 8
        return m
    }

    @Test func defaultIsTaggedRecommended() {
        let m = model(name: "Qwen3 4B Instruct", isDefault: true)
        #expect(m.menuTag == "recommended")
        #expect(m.menuTitle == "Qwen3 4B Instruct (recommended)")
    }

    @Test func nonCommercialIsTaggedBeforeDownload() {
        let m = model(name: "Qwen2.5 Coder 3B", license: "Qwen Research License (non-commercial)")
        #expect(m.menuTag == "non-commercial")
        #expect(m.menuTitle == "Qwen2.5 Coder 3B (non-commercial)")
        #expect(m.details.contains("NON-COMMERCIAL"))
        #expect(m.details.contains("License: Qwen Research License (non-commercial)."))
    }

    @Test func otherModelsAreTaggedWithTheirSize() {
        let m = model(name: "Qwen2.5 Coder 1.5B", size: 1_117_320_768)
        #expect(m.sizeLabel == "1.1 GB")
        #expect(m.menuTag == "1.1 GB")
        #expect(m.menuTitle == "Qwen2.5 Coder 1.5B (1.1 GB)")
    }

    @Test func recommendedWinsOverNonCommercial() {
        let m = model(license: "Some non-commercial license", isDefault: true)
        #expect(m.menuTag == "recommended")
        #expect(m.details.contains("NON-COMMERCIAL"))
    }

    @Test func detailsCarryWhatTheRowsUsedToShow() {
        let m = model(name: "Qwen Test 3B", size: 2_104_932_800)
        let d = m.details
        #expect(d.contains("Qwen Test 3B. Good code hints."))
        #expect(d.contains(m.shortDescription))
        #expect(d.contains("License: Apache-2.0."))
        #expect(d.contains("8 GB of memory"))
        #expect(d.contains("huggingface.co/x/y/resolve/"))
        #expect(!d.contains("NON-COMMERCIAL"))
    }

    @Test func automaticTitles() {
        #expect(BuiltInModel.automaticTitle(suggested: "qwen3-4b-instruct-2507-q4_k_m") == "Automatic (qwen3-4b-instruct-2507-q4_k_m)")
        #expect(BuiltInModel.automaticTitle(suggested: nil) == "Automatic (download a model)")
    }

    @Test func bundledCatalogTags() throws {
        let catalog = try #require(ModelCatalog.bundled())
        let tags = Dictionary(uniqueKeysWithValues: catalog.models.map { ($0.id, $0.menuTag) })
        #expect(tags["qwen3-4b-instruct-2507-q4_k_m"] == "recommended")
        #expect(tags["qwen2.5-coder-3b-instruct-q4_k_m"] == "non-commercial")
        #expect(tags["qwen2.5-coder-1.5b-instruct-q4_k_m"] == "1.1 GB")
        #expect(tags["qwen2.5-coder-7b-instruct-q4_k_m"] == "4.7 GB")
        #expect(tags["qwen3-4b-q4_k_m"] == "2.5 GB")
        #expect(Set(catalog.models.map(\.menuTitle)).count == catalog.models.count)
    }
}
