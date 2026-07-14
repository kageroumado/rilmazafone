import AppKit
import SwiftUI

struct ImageLayerInspector: View {
    let layer: BackgroundLayer
    @Binding var selectedItemID: UUID?

    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Section {
            HStack(spacing: 10) {
                if let image = document.backgroundImages[layer.id] {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Text(layer.label)
                    .lineLimit(1)
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

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Scale")
                    Spacer()
                    Text("\(Int(layer.scale * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Slider(
                    value: scaleBinding,
                    in: 0.1 ... 3.0,
                )
            }

            Button("Remove Layer", role: .destructive) {
                document.removeBackgroundLayer(layer.id, undoManager: undoManager)
                selectedItemID = nil
            }
            .controlSize(.small)
        }
    }

    // MARK: - Bindings

    private var xBinding: Binding<Double> {
        Binding(
            get: { round(layer.position.x) },
            set: { document.moveBackgroundLayer(layer.id, to: CGPoint(x: $0, y: layer.position.y), undoManager: undoManager) },
        )
    }

    private var yBinding: Binding<Double> {
        Binding(
            get: { round(layer.position.y) },
            set: { document.moveBackgroundLayer(layer.id, to: CGPoint(x: layer.position.x, y: $0), undoManager: undoManager) },
        )
    }

    private var scaleBinding: Binding<Double> {
        Binding(
            get: { layer.scale },
            set: { document.setBackgroundLayerScale(layer.id, to: $0, undoManager: undoManager) },
        )
    }
}
