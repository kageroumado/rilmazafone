import SwiftUI

/// A text layer's handle on the canvas.
///
/// The canvas paints the layer from the composite the build bakes, so this view shows
/// type only while the layer is selected — when it becomes an editable field, and when
/// dragging needs it to follow the pointer. Deselected, it is an invisible target the
/// size of the drawn text.
struct TextLayerCanvasView: View, Equatable {
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager

    let layer: TextLayerConfiguration
    let isSelected: Bool
    let zoom: CGFloat
    let onDragChanged: (CGPoint) -> CGPoint
    let onMove: (CGPoint) -> Void
    let onSelect: () -> Void

    nonisolated static func == (lhs: TextLayerCanvasView, rhs: TextLayerCanvasView) -> Bool {
        lhs.layer == rhs.layer
            && lhs.isSelected == rhs.isSelected
            && lhs.zoom == rhs.zoom
    }

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @FocusState private var isEditing: Bool

    var body: some View {
        Group {
            if isSelected {
                TextField("", text: textBinding)
                    .textFieldStyle(.plain)
                    .font(resolvedFont)
                    .bold(layer.isBold)
                    .italic(layer.isItalic)
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(.center)
                    .focused($isEditing)
                    .fixedSize()
            } else {
                Color.clear
                    .frame(width: drawnSize.width * zoom, height: drawnSize.height * zoom)
            }
        }
        .padding(4 * zoom)
        .contentShape(Rectangle())
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .position(
            x: layer.position.x * zoom + dragOffset.width,
            y: layer.position.y * zoom + dragOffset.height,
        )
        .gesture(dragGesture)
        .onTapGesture {
            onSelect()
        }
        .onChange(of: isSelected) { _, selected in
            if selected {
                isEditing = true
            }
        }
    }

    /// The layer's footprint in canvas points, measured the way the renderer draws it.
    private var drawnSize: CGSize {
        CompositeRenderer.attributedString(for: layer).size()
    }

    private var textColor: Color {
        Color(
            red: layer.color.red,
            green: layer.color.green,
            blue: layer.color.blue,
        )
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { layer.text },
            set: { document.setTextLayerText(layer.id, to: $0, undoManager: undoManager) },
        )
    }

    private var resolvedFont: Font {
        .custom(layer.fontFamily, size: layer.fontSize * zoom)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    onSelect()
                }
                let rawX = layer.position.x + value.translation.width / zoom
                let rawY = layer.position.y + value.translation.height / zoom
                let snapped = onDragChanged(CGPoint(x: rawX, y: rawY))
                dragOffset = CGSize(
                    width: (snapped.x - layer.position.x) * zoom,
                    height: (snapped.y - layer.position.y) * zoom,
                )
            }
            .onEnded { value in
                isDragging = false
                let rawX = layer.position.x + value.translation.width / zoom
                let rawY = layer.position.y + value.translation.height / zoom
                let snapped = onDragChanged(CGPoint(x: rawX, y: rawY))
                dragOffset = .zero
                onMove(CGPoint(x: round(snapped.x), y: round(snapped.y)))
            }
    }
}
