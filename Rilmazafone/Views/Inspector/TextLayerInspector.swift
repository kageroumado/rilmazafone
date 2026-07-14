import AppKit
import SwiftUI

struct TextLayerInspector: View {
    let layer: TextLayerConfiguration
    @Binding var selectedItemID: UUID?

    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager

    private let fontFamilies = [
        "SF Pro", "SF Pro Display", "SF Pro Text", "SF Pro Rounded",
        "SF Compact", "SF Compact Display", "SF Compact Text", "SF Compact Rounded",
        "Helvetica Neue", "Lucida Grande", "Avenir", "Futura",
        "Georgia", "Times New Roman", "Menlo", "Courier New",
    ]

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "textformat")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)

                TextField("", text: textBinding)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Position") {
                HStack(spacing: 4) {
                    Text("x")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", value: xBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)

                    Text("y")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", value: yBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)
                }
            }

            Picker("Font", selection: fontBinding) {
                ForEach(fontFamilies, id: \.self) { family in
                    Text(family).tag(family)
                }
            }

            LabeledContent("Size") {
                TextField("", value: fontSizeBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 55)

                Text("pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Toggle("Bold", isOn: boldBinding)
                    .toggleStyle(.button)
                    .font(.body.bold())

                Toggle("Italic", isOn: italicBinding)
                    .toggleStyle(.button)
                    .font(.body.italic())
            }

            ColorPicker(
                "Color",
                selection: colorBinding,
                supportsOpacity: false,
            )

            Button("Remove Text Layer", role: .destructive) {
                document.removeTextLayer(layer.id, undoManager: undoManager)
                selectedItemID = nil
            }
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    private func updateStyle(_ transform: (inout TextLayerConfiguration) -> Void) {
        document.updateTextLayerStyle(layer.id, with: transform, undoManager: undoManager)
    }

    // MARK: - Bindings

    private var textBinding: Binding<String> {
        Binding(
            get: { layer.text },
            set: { document.setTextLayerText(layer.id, to: $0, undoManager: undoManager) },
        )
    }

    private var xBinding: Binding<Double> {
        Binding(
            get: { round(layer.position.x) },
            set: { document.moveTextLayer(layer.id, to: CGPoint(x: $0, y: layer.position.y), undoManager: undoManager) },
        )
    }

    private var yBinding: Binding<Double> {
        Binding(
            get: { round(layer.position.y) },
            set: { document.moveTextLayer(layer.id, to: CGPoint(x: layer.position.x, y: $0), undoManager: undoManager) },
        )
    }

    private var fontBinding: Binding<String> {
        Binding(get: { layer.fontFamily }, set: { val in updateStyle { $0.fontFamily = val } })
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(get: { layer.fontSize }, set: { val in updateStyle { $0.fontSize = max(val, 1) } })
    }

    private var boldBinding: Binding<Bool> {
        Binding(get: { layer.isBold }, set: { val in updateStyle { $0.isBold = val } })
    }

    private var italicBinding: Binding<Bool> {
        Binding(get: { layer.isItalic }, set: { val in updateStyle { $0.isItalic = val } })
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { layer.color.swiftUIColor },
            set: { newColor in
                guard let rgb = RGBColor(swiftUIColor: newColor) else { return }
                updateStyle { $0.color = rgb }
            },
        )
    }
}
