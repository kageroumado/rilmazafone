import CoreGraphics

/// The composited, unblurred canvas content beneath item panels, tagged with the
/// generation of the background state it was rendered from.
///
/// `CanvasView` produces one per background "generation" (any background-affecting
/// edit — layers, gradient, text, symbols, window size — bumps the generation) via
/// `CompositeRenderer.renderPanelBackdrop` and shares it with every panel, so
/// dragging a panel never re-composites; it only re-renders that panel over this image.
nonisolated struct CanvasBackdrop: Equatable, @unchecked Sendable {
    /// Composited backdrop pixels (`pointSize` × `scale`).
    let image: CGImage
    /// Size of the DMG window content in canvas points.
    let pointSize: CGSize
    /// Pixels per point of `image`.
    let scale: CGFloat
    /// Fingerprint of the background state this image was rendered from.
    let generation: Int

    /// Pixel density the canvas composites at, matching the `@2x` representation the
    /// built background carries — so a panel previewed here is the panel Finder shows.
    static let renderScale: CGFloat = 2

    static func == (lhs: CanvasBackdrop, rhs: CanvasBackdrop) -> Bool {
        lhs.generation == rhs.generation
            && lhs.image === rhs.image
            && lhs.pointSize == rhs.pointSize
            && lhs.scale == rhs.scale
    }
}
