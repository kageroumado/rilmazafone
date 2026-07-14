import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

// MARK: - Canvas Backdrop

/// The composited, unblurred canvas content beneath item panels, tagged with the
/// generation of the background state it was rendered from.
///
/// `CanvasView` produces one per background "generation" (any background-affecting
/// edit — layers, gradient, text, symbols, window size — bumps the generation) via
/// `CompositeRenderer.renderPanelBackdrop` and shares it with every panel, so
/// dragging a panel never re-composites; it only re-crops and re-blurs this image.
nonisolated struct CanvasBackdrop: Equatable, @unchecked Sendable {
    /// Composited backdrop pixels (`pointSize` × the render scale).
    let image: CGImage
    /// Size of the DMG window content in canvas points.
    let pointSize: CGSize
    /// Fingerprint of the background state this image was rendered from.
    let generation: Int

    static func == (lhs: CanvasBackdrop, rhs: CanvasBackdrop) -> Bool {
        lhs.generation == rhs.generation
            && lhs.image === rhs.image
            && lhs.pointSize == rhs.pointSize
    }
}

// MARK: - Renderer

/// Public-API blur core for the live glass preview: crops the composited canvas
/// backdrop under a panel rect and Gaussian-blurs it with clamped edges.
nonisolated enum CanvasBackdropRenderer {
    /// GPU-backed CoreImage context for the interactive preview. Deliberately separate
    /// from `CompositeRenderer`'s software context: the live path favors latency, while
    /// the build path favors byte-determinism. Both share the fixed sRGB working space.
    private static let ciContext = CIContext(options: [
        .workingColorSpace: CompositeRenderer.sRGB,
        .outputColorSpace: CompositeRenderer.sRGB,
    ])

    /// Crops `backdrop` under `rect` and applies a Gaussian blur.
    ///
    /// The source is edge-clamped (`clampedToExtent`) before the blur and cropped back
    /// to the panel rect afterward, so pixels near the window edge sample repeated edge
    /// content instead of transparency and the result does not darken at the borders.
    ///
    /// - Parameters:
    ///   - backdrop: Composited canvas content at some uniform pixel scale.
    ///   - backdropPointSize: The canvas point size `backdrop` covers.
    ///   - rect: Panel rect in canvas points, top-left origin (y down), matching
    ///     `CanvasItem.position` coordinates.
    ///   - blurRadius: Gaussian blur radius in canvas points.
    /// - Returns: The blurred crop at `backdrop`'s pixel scale, or `nil` if the inputs
    ///   are degenerate or rendering fails.
    static func blurredCrop(
        from backdrop: CGImage,
        backdropPointSize: CGSize,
        rect: CGRect,
        blurRadius: CGFloat
    ) -> CGImage? {
        guard backdropPointSize.width > 0, backdropPointSize.height > 0,
              rect.width > 0, rect.height > 0
        else { return nil }

        let scale = CGFloat(backdrop.width) / backdropPointSize.width
        let flippedMinY = backdropPointSize.height - rect.maxY
        let rectPx = CGRect(
            x: rect.minX * scale,
            y: flippedMinY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = CIImage(cgImage: backdrop).clampedToExtent()
        blur.radius = Float(blurRadius * scale)

        guard let blurred = blur.outputImage?.cropped(to: rectPx) else { return nil }
        return ciContext.createCGImage(blurred, from: rectPx)
    }
}

// MARK: - Blur Crop Cache

/// Caches blurred crops keyed on (generation, panel rect rounded to pixels, radius),
/// so a static panel costs a dictionary lookup per body evaluation and nothing per
/// frame. A generation bump (any background edit) invalidates everything.
@MainActor
private enum CanvasBackdropBlurCache {
    struct Key: Hashable {
        let generation: Int
        let xPx: Int
        let yPx: Int
        let widthPx: Int
        let heightPx: Int
        let radiusCentipoints: Int

        init(backdrop: CanvasBackdrop, rect: CGRect, blurRadius: CGFloat) {
            generation = backdrop.generation
            let scale = CGFloat(backdrop.image.width) / backdrop.pointSize.width
            let rectPx = rect.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
            xPx = Int(rectPx.minX)
            yPx = Int(rectPx.minY)
            widthPx = Int(rectPx.width)
            heightPx = Int(rectPx.height)
            radiusCentipoints = Int((blurRadius * 100).rounded())
        }
    }

    private static let capacity = 96
    private static var store: [Key: CGImage] = [:]
    private static var insertionOrder: [Key] = []

    static func image(for key: Key) -> CGImage? {
        store[key]
    }

    static func insert(_ image: CGImage, for key: Key) {
        if let latest = insertionOrder.last, latest.generation != key.generation {
            store.removeAll(keepingCapacity: true)
            insertionOrder.removeAll(keepingCapacity: true)
        }
        guard store[key] == nil else { return }
        store[key] = image
        insertionOrder.append(key)
        if insertionOrder.count > capacity {
            let evicted = insertionOrder.removeFirst()
            store[evicted] = nil
        }
    }
}

// MARK: - View

/// Public-API stand-in for the private `BackdropBlurView`: shows the panel's glass
/// backdrop by blurring the already-composited canvas background under the panel rect
/// with `CIGaussianBlur`.
///
/// This intentionally blurs only the *background* (base fill, image layers, text, SF
/// symbols) and not icons passing beneath — matching the built DMG, where
/// `CompositeRenderer` bakes panels into the background the same way.
///
/// The view fills whatever frame its parent proposes (the panel's zoomed square), so
/// all geometry here stays in unzoomed canvas points and the blurred crop is scaled
/// for display, exactly like the baked background is.
struct CanvasBackdropBlurView: View {
    /// Shared composited background; `nil` renders clear until the canvas provides one.
    let backdrop: CanvasBackdrop?
    /// Panel rect in canvas points, top-left origin.
    let rect: CGRect
    /// Blur radius in canvas points.
    let blurRadius: CGFloat

    @State private var blurredImage: CGImage?

    private var cacheKey: CanvasBackdropBlurCache.Key? {
        backdrop.map { CanvasBackdropBlurCache.Key(backdrop: $0, rect: rect, blurRadius: blurRadius) }
    }

    var body: some View {
        ZStack {
            if let blurredImage {
                Image(decorative: blurredImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
            } else {
                Color.clear
            }
        }
        .task(id: cacheKey) {
            await refreshBlurredImage()
        }
    }

    private func refreshBlurredImage() async {
        guard let backdrop, let cacheKey, blurRadius > 0 else {
            blurredImage = nil
            return
        }

        if let cached = CanvasBackdropBlurCache.image(for: cacheKey) {
            blurredImage = cached
            return
        }

        let request = (backdrop: backdrop, rect: rect, blurRadius: blurRadius)
        let rendered = await Task.detached(name: "Glass Preview Blur", priority: .userInitiated) {
            CanvasBackdropRenderer.blurredCrop(
                from: request.backdrop.image,
                backdropPointSize: request.backdrop.pointSize,
                rect: request.rect,
                blurRadius: request.blurRadius
            )
        }.value

        guard let rendered else { return }
        CanvasBackdropBlurCache.insert(rendered, for: cacheKey)
        if !Task.isCancelled {
            blurredImage = rendered
        }
    }
}
