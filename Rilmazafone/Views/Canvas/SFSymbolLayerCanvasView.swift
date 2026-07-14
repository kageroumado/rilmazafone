import SwiftUI

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
        Image(systemName: layer.symbolName)
            .font(.system(size: layer.pointSize * zoom, weight: layer.weight.fontWeight))
            .foregroundStyle(symbolColor)
            .padding(4 * zoom)
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
