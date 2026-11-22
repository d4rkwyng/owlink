import SwiftUI
import CedricAI

/// A built-in model waiting on its licence before download.
struct ModelLicenceRequest: Identifiable {
    let model: BuiltInModel
    let confirmation: BuiltInModelLicenseConfirmation
    var id: String { model.id }
}

/// The full bundled licence text (never fetched), with Confirm only once
/// its end has been visible (or the text appeared with assistive technology).
struct ModelLicenceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlEnabled
    @State private var reachedEnd = false
    @State private var textShown = false
    let confirmation: BuiltInModelLicenseConfirmation
    let onConfirm: () -> Void

    private var assistiveAccess: Bool { voiceOverEnabled || switchControlEnabled }
    private var canConfirm: Bool { reachedEnd || (assistiveAccess && textShown) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                if confirmation.isNonCommercial {
                    Text(String(localized: "NON-COMMERCIAL licence"))
                        .font(.headline).foregroundStyle(.red)
                }
                Text(String(localized: "Licence: \(confirmation.licenseName). Review the full licence below before downloading."))
                GeometryReader { viewport in
                    ScrollView {
                        VStack(spacing: 0) {
                            Text(confirmation.body)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("licence.text")
                                .onAppear { textShown = !confirmation.body.isEmpty }
                            Color.clear.frame(height: 0)
                                .background(GeometryReader { marker in
                                    Color.clear.preference(key: LicenceEndPosition.self,
                                        value: LicenceEndPosition.Position(
                                            y: marker.frame(in: .named("licenceScroll")).minY,
                                            height: viewport.size.height))
                                })
                        }
                    }
                    .coordinateSpace(name: "licenceScroll")
                    .onPreferenceChange(LicenceEndPosition.self) { position in
                        if let position, position.height > 0, position.y >= 0,
                           position.y <= position.height + 1, !confirmation.body.isEmpty {
                            reachedEnd = true
                        }
                    }
                }
                if !reachedEnd && !assistiveAccess {
                    Text(String(localized: "Scroll to the end to confirm."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
            .navigationTitle(confirmation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                        .accessibilityIdentifier("licence.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Confirm")) { onConfirm(); dismiss() }
                        .disabled(!canConfirm)
                        .accessibilityIdentifier("licence.confirm")
                }
            }
        }
    }
}

private struct LicenceEndPosition: PreferenceKey {
    struct Position: Equatable {
        let y: CGFloat
        let height: CGFloat
    }

    static var defaultValue: Position? { nil }
    static func reduce(value: inout Position?, nextValue: () -> Position?) { value = nextValue() ?? value }
}

#if DEBUG
/// `-OwlinkShowLicence <model id | first>`: the sheet alone, for screenshots. Downloads nothing.
struct ModelLicencePreview: View {
    let resolvedRequest: ModelLicenceRequest?
    @State private var request: ModelLicenceRequest?
    @State private var missingLicence = false

    static func resolve(modelID: String) -> ModelLicencePreview? {
        guard let catalog = ModelCatalog.bundled(),
              let model = modelID == "first" ? catalog.models.first : catalog.model(id: modelID) else {
            NSLog("Could not find model for -OwlinkShowLicence: %@", modelID)
            return nil
        }
        let request = model.licenseConfirmation().map { ModelLicenceRequest(model: model, confirmation: $0) }
        return ModelLicencePreview(resolvedRequest: request)
    }

    var body: some View {
        Color.clear
            .onAppear {
                if let resolvedRequest { request = resolvedRequest }
                else { missingLicence = true }
            }
            .sheet(item: $request) { request in
                ModelLicenceSheet(confirmation: request.confirmation) {}
            }
            .alert(String(localized: "Couldn’t load the model licence"), isPresented: $missingLicence) {
                Button(String(localized: "OK"), role: .cancel) {}
            } message: {
                Text(String(localized: "The bundled licence text is missing. No download was started."))
            }
    }
}
#endif
