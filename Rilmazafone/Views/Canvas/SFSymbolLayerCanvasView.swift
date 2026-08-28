import SwiftUI

/// An SF Symbol layer's handle on the canvas.
///
/// The canvas paints the layer from the composite the build bakes, so this view shows
/// the glyph only while the layer is selected and needs to follow the pointer.
/// Deselected, it is an invisible target the size of the drawn symbol.
struct SFSymbolLayerCanvasView: View, Equatable {
    let layer: SFSymbolLayerConfiguration
    let isSelected: Bool
    let zoom: CGFloat
    let onDragChanged: (CGPoint) -> CGPoint
    let onMove: (CGPoint) -> Void
    let onSelect: () -> Void

    nonisolated static func == (lhs: SFSymbolLayerCanvasView, rhs: SFSymbolLayerCanvasView) -> Bool {
        lhs.layer == rhs.layer
            && lhs.isSelected == rhs.isSelected
            && lhs.zoom == rhs.zoom
    }

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false

    var body: some View {
        Group {
            if isSelected {
                Image(systemName: layer.symbolName)
                    .font(.system(size: layer.pointSize * zoom, weight: layer.weight.fontWeight))
                    .foregroundStyle(symbolColor)
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
    }

    /// The layer's footprint in canvas points, measured the way the renderer draws it.
    private var drawnSize: CGSize {
        CompositeRenderer.symbolImage(for: layer)?.size ?? CGSize(width: layer.pointSize, height: layer.pointSize)
    }

    private var symbolColor: Color {
        Color(
            red: layer.color.red,
            green: layer.color.green,
            blue: layer.color.blue,
        )
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

extension SFSymbolWeight {
    var fontWeight: Font.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }
}
