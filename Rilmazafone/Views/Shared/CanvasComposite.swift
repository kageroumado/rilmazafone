import CoreGraphics

/// Everything the canvas paints beneath the icons, tagged with the generation of the
/// document state it was rendered from.
///
/// `CanvasView` produces one per generation — any edit that changes the picture bumps
/// it — via `CompositeRenderer.renderCanvasComposite`. It is the whole background:
/// base, image layers, type, symbols, item panels, and grain.
nonisolated struct CanvasComposite: Equatable, @unchecked Sendable {
    /// Composited pixels (`pointSize` × `scale`).
    let image: CGImage
    /// Size of the DMG window content in canvas points.
    let pointSize: CGSize
    /// Pixels per point of `image`.
    let scale: CGFloat
    /// Fingerprint of the background state this image was rendered from.
    let generation: Int

    /// Pixel density the canvas composites at when it is not being dragged, matching the
    /// `@2x` representation the built background carries.
    static let renderScale: CGFloat = 2

    static func == (lhs: CanvasComposite, rhs: CanvasComposite) -> Bool {
        lhs.generation == rhs.generation
            && lhs.image === rhs.image
            && lhs.pointSize == rhs.pointSize
            && lhs.scale == rhs.scale
    }
}
