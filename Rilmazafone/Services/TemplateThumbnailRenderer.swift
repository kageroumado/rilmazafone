import AppKit

/// Renders template thumbnails: the full `CompositeRenderer` composite
/// (background, gradients, text, symbols, baked panels) with item tiles drawn
/// on top — real icons where the registry could resolve them, and the same
/// dashed generic-app tile the canvas shows for an unfilled placeholder.
nonisolated enum TemplateThumbnailRenderer {
    /// Geometry mirrors `CanvasItemView`/`CompositeRenderer`: the iloc position
    /// is the center of icon cell + text, so the icon sits above it.
    private enum Metrics {
        static let scale: CGFloat = 2
        static let iconCellPadding: CGFloat = 10
        static let textGap: CGFloat = 4
        static let estimatedTextHeight: CGFloat = 20
        static let placeholderLineWidth: CGFloat = 2
        static let placeholderDash: [CGFloat] = [6, 4]
        static let placeholderCornerRadiusRatio: CGFloat = 0.2
        static let placeholderSymbolInsetRatio: CGFloat = 0.26
        static let placeholderStrokeGray: CGFloat = 0.42
        static let placeholderStrokeAlpha: CGFloat = 0.6
        static let placeholderSymbolGray: CGFloat = 0.45
        static let placeholderSymbolAlpha: CGFloat = 0.4
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Renders the thumbnail at 2x pixel density off the caller's executor and
    /// returns it as a `CGImage` sized `windowSize × 2`.
    @concurrent
    static func render(
        configuration: DMGConfiguration,
        assetsDirectory: URL,
        itemIcons: [UUID: CGImage]
    ) async -> CGImage? {
        let width = configuration.window.width
        let height = configuration.window.height
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil,
                  width: max(Int((width * Metrics.scale).rounded()), 1),
                  height: max(Int((height * Metrics.scale).rounded()), 1),
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: Metrics.scale, y: Metrics.scale)

        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        if let background = CompositeRenderer.renderBackground(
            configuration: configuration,
            assetsDirectory: assetsDirectory
        ) {
            background.draw(
                in: CGRect(x: 0, y: 0, width: width, height: height),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
        }

        for item in configuration.items {
            let rect = iconRect(
                for: item,
                iconSize: configuration.iconSize,
                canvasHeight: height
            )
            if let icon = itemIcons[item.id] {
                context.draw(icon, in: rect)
            } else if item.isPlaceholder {
                drawPlaceholderTile(in: rect, context: context)
            }
        }

        return context.makeImage()
    }

    /// The icon's rect in y-up canvas coordinates. The item position is the
    /// center of icon cell + label, so the icon center sits half the label
    /// area above it.
    private static func iconRect(
        for item: CanvasItem,
        iconSize: CGFloat,
        canvasHeight: CGFloat
    ) -> CGRect {
        let contentHeight = iconSize
            + Metrics.iconCellPadding * 2
            + Metrics.textGap
            + Metrics.estimatedTextHeight
        let iconCenterYTopDown = item.position.y
            - contentHeight / 2
            + Metrics.iconCellPadding
            + iconSize / 2
        return CGRect(
            x: item.position.x - iconSize / 2,
            y: canvasHeight - iconCenterYTopDown - iconSize / 2,
            width: iconSize,
            height: iconSize
        )
    }

    /// Dashed rounded-rect outline with a tinted `app.dashed` glyph — the same
    /// visual language as the canvas placeholder tile.
    private static func drawPlaceholderTile(in rect: CGRect, context: CGContext) {
        let cornerRadius = rect.width * Metrics.placeholderCornerRadiusRatio
        let strokeRect = rect.insetBy(
            dx: Metrics.placeholderLineWidth / 2,
            dy: Metrics.placeholderLineWidth / 2
        )

        context.saveGState()
        context.setStrokeColor(CGColor(
            gray: Metrics.placeholderStrokeGray,
            alpha: Metrics.placeholderStrokeAlpha
        ))
        context.setLineWidth(Metrics.placeholderLineWidth)
        context.setLineDash(phase: 0, lengths: Metrics.placeholderDash)
        context.addPath(CGPath(
            roundedRect: strokeRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        ))
        context.strokePath()
        context.restoreGState()

        guard let symbol = NSImage(
            systemSymbolName: "app.dashed",
            accessibilityDescription: nil
        ) else { return }

        let inset = rect.width * Metrics.placeholderSymbolInsetRatio
        let symbolBounds = rect.insetBy(dx: inset, dy: inset)
        let symbolRect = aspectFit(symbol.size, in: symbolBounds)

        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        symbol.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        context.setBlendMode(.sourceAtop)
        context.setFillColor(CGColor(
            gray: Metrics.placeholderSymbolGray,
            alpha: Metrics.placeholderSymbolAlpha
        ))
        context.fill(symbolRect)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func aspectFit(_ size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let ratio = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * ratio, height: size.height * ratio)
        return CGRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}
