import SwiftUI

/// Editor for a mesh gradient: a grid of color wells, one per control point, over a
/// preview drawn by the renderer that bakes the background.
struct MeshGradientEditor: View {
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager

    @State private var preview: CGImage?

    private static let previewSize = CGSize(width: 240, height: 120)
    private static let gridRange = 2 ... 5

    private var mesh: MeshGradientConfiguration {
        document.background.mesh ?? MeshGradientConfiguration()
    }

    var body: some View {
        previewSwatch

        Stepper(value: columnsBinding, in: Self.gridRange) {
            LabeledContent("Columns") {
                Text("\(mesh.columns)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }

        Stepper(value: rowsBinding, in: Self.gridRange) {
            LabeledContent("Rows") {
                Text("\(mesh.rows)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }

        Toggle("Smooth Colors", isOn: smoothsColorsBinding)
            .toggleStyle(.switch)

        colorGrid
    }

    // MARK: - Preview

    private var previewSwatch: some View {
        Group {
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .interpolation(.high)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .task(id: mesh) {
            preview = CompositeRenderer.renderMeshImage(
                mesh: mesh,
                pixelsWide: Int(Self.previewSize.width),
                pixelsHigh: Int(Self.previewSize.height),
            )
        }
    }

    // MARK: - Control Points

    /// One well per control point, laid out the way the grid is — so the well you reach
    /// for sits where its color shows in the preview above.
    private var colorGrid: some View {
        VStack(spacing: 4) {
            ForEach(0 ..< mesh.rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0 ..< mesh.columns, id: \.self) { column in
                        ColorPicker(
                            "",
                            selection: colorBinding(column: column, row: row),
                            supportsOpacity: false,
                        )
                        .labelsHidden()
                    }
                }
            }
        }
        .accessibilityLabel("Mesh control point colors")
    }

    // MARK: - Bindings

    private func update(_ transform: (inout MeshGradientConfiguration) -> Void) {
        var updated = mesh
        transform(&updated)
        document.setMeshConfiguration(to: updated, undoManager: undoManager)
    }

    private var columnsBinding: Binding<Int> {
        Binding(
            get: { mesh.columns },
            set: { document.setMeshConfiguration(to: mesh.resized(columns: $0, rows: mesh.rows), undoManager: undoManager) },
        )
    }

    private var rowsBinding: Binding<Int> {
        Binding(
            get: { mesh.rows },
            set: { document.setMeshConfiguration(to: mesh.resized(columns: mesh.columns, rows: $0), undoManager: undoManager) },
        )
    }

    private var smoothsColorsBinding: Binding<Bool> {
        Binding(
            get: { mesh.smoothsColors },
            set: { value in update { $0.smoothsColors = value } },
        )
    }

    private func colorBinding(column: Int, row: Int) -> Binding<Color> {
        Binding(
            get: { mesh.point(column: column, row: row)?.color.swiftUIColor ?? .gray },
            set: { newColor in
                guard let rgb = RGBColor(swiftUIColor: newColor) else { return }
                let index = row * mesh.columns + column
                update { config in
                    guard config.points.indices.contains(index) else { return }
                    config.points[index].color = rgb
                }
            },
        )
    }
}
