import SwiftUI
import UniformTypeIdentifiers

struct BackgroundSection: View {
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager

    @State private var isImagePickerPresented = false

    var body: some View {
        Section("Background") {
            Picker("Type", selection: Binding(
                get: { document.background.type },
                set: { newType in
                    document.setBackgroundType(newType, undoManager: undoManager)
                    // Auto-create gradient config when switching to gradient
                    if newType == .gradient, document.background.gradient == nil {
                        document.setGradientConfiguration(to: GradientConfiguration(), undoManager: undoManager)
                    }
                },
            )) {
                Text("None").tag(BackgroundType.none)
                Text("Color").tag(BackgroundType.color)
                Text("Gradient").tag(BackgroundType.gradient)
                Text("Image").tag(BackgroundType.image)
            }
            .pickerStyle(.segmented)

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
