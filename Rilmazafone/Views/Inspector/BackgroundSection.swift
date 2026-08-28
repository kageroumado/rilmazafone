import SwiftUI
import UniformTypeIdentifiers

struct BackgroundSection: View {
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager

    @State private var isImagePickerPresented = false
    @State private var grainExpanded = false

    var body: some View {
        Section("Background") {
            Picker("Type", selection: Binding(
                get: { document.background.type },
                set: { newType in
                    document.setBackgroundType(newType, undoManager: undoManager)
                    // Auto-create the configuration the new type needs, so switching to
                    // it shows something rather than an empty window.
                    if newType == .gradient, document.background.gradient == nil {
                        document.setGradientConfiguration(to: GradientConfiguration(), undoManager: undoManager)
                    }
                    if newType == .mesh, document.background.mesh == nil {
                        document.setMeshConfiguration(to: MeshGradientConfiguration(), undoManager: undoManager)
                    }
                },
            )) {
                ForEach(BackgroundType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            // A pop-up rather than a segmented control: five labels of uneven width do
            // not fit the inspector's column, and a segmented control clips rather than
            // compresses — the leading segment loses its label entirely.
            .pickerStyle(.menu)

            switch document.background.type {
            case .none:
                EmptyView()

            case .color:
                ColorPicker(
                    "Color",
                    selection: colorBinding,
                    supportsOpacity: false,
                )

            case .gradient:
                GradientEditor()

            case .mesh:
                MeshGradientEditor()

            case .image:
                let layerCount = document.background.layers.count
                if layerCount > 0 {
                    LabeledContent("Layers") {
                        Text("\(layerCount)")
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Add Image\u{2026}") {
                    isImagePickerPresented = true
                }

                if !document.background.layers.isEmpty {
                    Button("Remove All", role: .destructive) {
                        let layerIDs = document.background.layers.map(\.id)
                        for id in layerIDs {
                            document.removeBackgroundLayer(id, undoManager: undoManager)
                        }
                    }
                }

                Text("Add images via the sidebar or drag them onto the canvas. Layers can be repositioned and scaled.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            grainGroup
        }
        .fileImporter(
            isPresented: $isImagePickerPresented,
            allowedContentTypes: [.png, .jpeg, .tiff],
            allowsMultipleSelection: true,
        ) { result in
            if case let .success(urls) = result {
                for url in urls {
                    do {
                        try document.importBackgroundImage(from: url, undoManager: undoManager)
                    } catch {
                        NSAlert.showError("Failed to import image", detail: error.localizedDescription)
                    }
                }
            }
        }
    }

    // MARK: - Grain

    /// Grain sits under the background type rather than inside it: it is a finish over
    /// whatever the background turned out to be, ramps included.
    private var grainGroup: some View {
        let grain = document.background.grain ?? GrainConfiguration()
        let isOn = document.background.grain?.enabled ?? false

        return DisclosureGroup(isExpanded: $grainExpanded) {
            Group {
                InspectorSliderRow(label: "Amount", value: grainAmountBinding(grain), range: 0 ... 0.3, format: .percent)
                InspectorSliderRow(label: "Size", value: grainSizeBinding(grain), range: 0.5 ... 6, unit: "px", format: .decimal)
                Toggle("Colored", isOn: grainColoredBinding(grain))
                    .toggleStyle(.switch)

                Text("A small amount dithers away the banding an 8-bit ramp shows across a window this size. Larger amounts read as film grain.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .disabled(!isOn)
            .padding(.top, 16)
        } label: {
            Toggle("Grain", isOn: grainEnabledBinding)
                .toggleStyle(.switch)
        }
    }

    private var grainEnabledBinding: Binding<Bool> {
        Binding(
            get: { document.background.grain?.enabled ?? false },
            set: { enabled in
                var grain = document.background.grain ?? GrainConfiguration()
                grain.enabled = enabled
                document.setGrainConfiguration(to: grain, undoManager: undoManager)
            },
        )
    }

    private func updateGrain(_ transform: (inout GrainConfiguration) -> Void) {
        var grain = document.background.grain ?? GrainConfiguration()
        transform(&grain)
        document.setGrainConfiguration(to: grain, undoManager: undoManager)
    }

    private func grainAmountBinding(_ grain: GrainConfiguration) -> Binding<Double> {
        Binding(get: { grain.amount }, set: { value in updateGrain { $0.amount = value } })
    }

    private func grainSizeBinding(_ grain: GrainConfiguration) -> Binding<Double> {
        Binding(get: { grain.size }, set: { value in updateGrain { $0.size = value } })
    }

    private func grainColoredBinding(_ grain: GrainConfiguration) -> Binding<Bool> {
        Binding(get: { grain.isColored }, set: { value in updateGrain { $0.isColored = value } })
    }

    /// Stable color binding that avoids feedback loops by using explicit sRGB throughout.
    private var colorBinding: Binding<Color> {
        Binding(
            get: { document.background.color.swiftUIColor },
            set: { newColor in
                guard let newRGB = RGBColor(swiftUIColor: newColor) else { return }
                let old = document.background.color
                guard abs(newRGB.red - old.red) > 0.001
                    || abs(newRGB.green - old.green) > 0.001
                    || abs(newRGB.blue - old.blue) > 0.001 else { return }
                document.setBackgroundColor(newRGB, undoManager: undoManager)
            },
        )
    }
}
