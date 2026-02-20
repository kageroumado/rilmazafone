import AppKit
import SwiftUI

struct SFSymbolLayerInspector: View {
    let layer: SFSymbolLayerConfiguration
    @Binding var selectedItemID: UUID?

    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager

    private let commonSymbols = [
        "arrow.right", "arrow.left", "arrow.down", "arrow.up",
        "arrow.right.circle", "chevron.right",
    ]

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: layer.symbolName)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)

                TextField("Symbol Name", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Quick Pick") {
                HStack(spacing: 6) {
                    ForEach(commonSymbols, id: \.self) { name in
                        Button {
                            document.updateSFSymbolLayerStyle(
                                layer.id,
                                with: { $0.symbolName = name },
                                undoManager: undoManager
                            )
                        } label: {
                            Image(systemName: name)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.borderless)
                        .opacity(layer.symbolName == name ? 1 : 0.5)
                    }
                }
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

            LabeledContent("Size") {
                TextField("", value: sizeBinding, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 55)

                Text("pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Weight", selection: weightBinding) {
                ForEach(SFSymbolWeight.allCases, id: \.self) { weight in
                    Text(weight.rawValue).tag(weight)
                }
            }

            ColorPicker(
                "Color",
                selection: colorBinding,
                supportsOpacity: false
            )

            Button("Remove Symbol Layer", role: .destructive) {
                document.removeSFSymbolLayer(layer.id, undoManager: undoManager)
                selectedItemID = nil
            }
            .controlSize(.small)
        }
    }

    // MARK: - Helpers

    private func updateStyle(_ transform: (inout SFSymbolLayerConfiguration) -> Void) {
        document.updateSFSymbolLayerStyle(layer.id, with: transform, undoManager: undoManager)
    }

    // MARK: - Bindings

    private var nameBinding: Binding<String> {
        Binding(get: { layer.symbolName }, set: { val in updateStyle { $0.symbolName = val } })
    }

    private var xBinding: Binding<Double> {
        Binding(
            get: { round(layer.position.x) },
            set: { document.moveSFSymbolLayer(layer.id, to: CGPoint(x: $0, y: layer.position.y), undoManager: undoManager) }
        )
    }

    private var yBinding: Binding<Double> {
        Binding(
            get: { round(layer.position.y) },
            set: { document.moveSFSymbolLayer(layer.id, to: CGPoint(x: layer.position.x, y: $0), undoManager: undoManager) }
        )
    }

    private var sizeBinding: Binding<Double> {
        Binding(get: { layer.pointSize }, set: { val in updateStyle { $0.pointSize = max(val, 1) } })
    }

    private var weightBinding: Binding<SFSymbolWeight> {
        Binding(get: { layer.weight }, set: { val in updateStyle { $0.weight = val } })
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { layer.color.swiftUIColor },
            set: { newColor in
                guard let rgb = RGBColor(swiftUIColor: newColor) else { return }
                updateStyle { $0.color = rgb }
            }
        )
    }
}
