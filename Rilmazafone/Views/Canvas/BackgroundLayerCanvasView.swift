import SwiftUI

struct BackgroundLayerCanvasView: View, Equatable {
    let layer: BackgroundLayer
    let image: NSImage
    let isSelected: Bool
    let zoom: CGFloat
    let windowWidth: CGFloat
    let onDragChanged: (CGPoint) -> CGPoint
    let onMove: (CGPoint) -> Void
    let onSelect: () -> Void

    nonisolated static func == (lhs: BackgroundLayerCanvasView, rhs: BackgroundLayerCanvasView) -> Bool {
        lhs.layer == rhs.layer
            && lhs.image === rhs.image
            && lhs.isSelected == rhs.isSelected
            && lhs.zoom == rhs.zoom
            && lhs.windowWidth == rhs.windowWidth
    }

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var processedImage: NSImage?

    private var aspectRatio: CGFloat {
        guard image.size.width > 0 else { return 1 }
        return image.size.height / image.size.width
    }

    /// Logical display size (without zoom) — matches the build pipeline dimensions.
    private var logicalWidth: CGFloat {
        windowWidth * layer.scale
    }
    private var logicalHeight: CGFloat {
        logicalWidth * aspectRatio
    }

    /// Actual on-screen size (with zoom).
    private var displayWidth: CGFloat {
        logicalWidth * zoom
    }
    private var displayHeight: CGFloat {
        logicalHeight * zoom
    }

    private var hasEffects: Bool {
        layer.blurRadius > 0 || layer.variableBlur != nil
            || layer.colorAdjustments != nil || layer.vignette != nil || layer.bloom != nil
    }

    /// Hash of parameters that affect the pre-rendered result.
    private var effectsFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(layer.blurRadius)
        hasher.combine(layer.variableBlur)
        hasher.combine(layer.colorAdjustments)
        hasher.combine(layer.vignette)
        hasher.combine(layer.bloom)
        hasher.combine(layer.scale)
        hasher.combine(windowWidth)
        hasher.combine(image.size.width)
        hasher.combine(image.size.height)
        return hasher.finalize()
    }

    var body: some View {
        Image(nsImage: processedImage ?? image)
            .resizable()
            .frame(width: displayWidth, height: displayHeight)
            .overlay {
                if isSelected {
                    Rectangle()
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
            .task(id: effectsFingerprint) {
                guard hasEffects else {
                    processedImage = nil
                    return
                }
                processedImage = CompositeRenderer.applyLayerEffects(
                    to: image,
                    layer: layer,
                    displaySize: CGSize(width: logicalWidth, height: logicalHeight),
                )
            }
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
