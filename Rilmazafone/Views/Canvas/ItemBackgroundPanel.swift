import CoreGraphics
import SwiftUI

/// One item's panel on the canvas, drawn by the renderer that bakes it into the DMG.
///
/// The panel is not reconstructed in SwiftUI. `CompositeRenderer.renderPanelPreview`
/// composites it over the shared canvas backdrop using the build's own drawing code,
/// and this view scales the result to the current zoom. The shadow's shape, the body's
/// blend against the background, and the bevel's clip are therefore exactly what the
/// built DMG will show, instead of a second implementation that drifts from it.
struct ItemBackgroundPanel: View, Equatable {
    let item: CanvasItem
    let bg: ItemBackground
    let currentZoom: CGFloat
    let iconSize: CGFloat
    let backdrop: CanvasBackdrop?

    nonisolated static func == (lhs: ItemBackgroundPanel, rhs: ItemBackgroundPanel) -> Bool {
        lhs.item == rhs.item
            && lhs.bg == rhs.bg
            && lhs.currentZoom == rhs.currentZoom
            && lhs.iconSize == rhs.iconSize
            && lhs.backdrop == rhs.backdrop
    }

    @State private var rendered: RenderedPanel?

    /// The panel's own rect in canvas points, top-left origin.
    private var panelRect: CGRect {
        ItemGeometry.panelRect(center: item.position, iconSize: iconSize, padding: bg.padding)
    }

    private var cacheKey: PanelRenderCache.Key? {
        backdrop.map { PanelRenderCache.Key(backdrop: $0, panelRect: panelRect, background: bg) }
    }

    var body: some View {
        Group {
            if let rendered {
                Image(decorative: rendered.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(
                        width: rendered.region.width * currentZoom,
                        height: rendered.region.height * currentZoom,
                    )
                    .position(
                        x: rendered.region.midX * currentZoom,
                        y: rendered.region.midY * currentZoom,
                    )
            }
        }
        .allowsHitTesting(false)
        .task(id: cacheKey) {
            await refresh()
        }
    }

    private func refresh() async {
        guard let backdrop, let cacheKey else {
            rendered = nil
            return
        }

        if let cached = PanelRenderCache.panel(for: cacheKey) {
            rendered = cached
            return
        }

        let request = (backdrop: backdrop, bg: bg, panelRect: panelRect)
        let result = await Task.detached(name: "Item Panel Preview", priority: .userInitiated) {
            CompositeRenderer.renderPanelPreview(
                bg: request.bg,
                panelRect: request.panelRect,
                backdrop: request.backdrop.image,
                backdropPointSize: request.backdrop.pointSize,
                scale: request.backdrop.scale,
            )
        }.value

        guard let result else { return }
        let panel = RenderedPanel(region: result.region, image: result.image)
        PanelRenderCache.insert(panel, for: cacheKey)
        if !Task.isCancelled {
            rendered = panel
        }
    }
}

// MARK: - Rendered Panel

/// A composited panel and the canvas-point region it fills. The region is wider than the
/// panel itself wherever the shadow or the body blur reaches outside it.
private struct RenderedPanel {
    let region: CGRect
    let image: CGImage
}

// MARK: - Cache

/// Caches composited panels keyed on (generation, panel rect rounded to pixels,
/// configuration), so a panel that is not being edited costs a dictionary lookup per
/// body evaluation and nothing per frame. A generation bump (any background edit)
/// invalidates everything.
@MainActor
private enum PanelRenderCache {
    struct Key: Hashable {
        let generation: Int
        let xPx: Int
        let yPx: Int
        let widthPx: Int
        let heightPx: Int
        let background: ItemBackground

        init(backdrop: CanvasBackdrop, panelRect: CGRect, background: ItemBackground) {
            generation = backdrop.generation
            let scale = backdrop.scale
            let rectPx = panelRect.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
            xPx = Int(rectPx.minX)
            yPx = Int(rectPx.minY)
            widthPx = Int(rectPx.width)
            heightPx = Int(rectPx.height)
            self.background = background
        }
    }

    private static let capacity = 96
    private static var store: [Key: RenderedPanel] = [:]
    private static var insertionOrder: [Key] = []

    static func panel(for key: Key) -> RenderedPanel? {
        store[key]
    }

    static func insert(_ panel: RenderedPanel, for key: Key) {
        if let latest = insertionOrder.last, latest.generation != key.generation {
            store.removeAll(keepingCapacity: true)
            insertionOrder.removeAll(keepingCapacity: true)
        }
        guard store[key] == nil else { return }
        store[key] = panel
        insertionOrder.append(key)
        if insertionOrder.count > capacity {
            let evicted = insertionOrder.removeFirst()
            store[evicted] = nil
        }
    }
}
