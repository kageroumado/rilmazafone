import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Rilmazafone

@Suite("Item panel rendering")
@MainActor
struct ItemPanelRenderingTests {
    // MARK: - Fixtures

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let canvas = CGSize(width: 400, height: 400)
    private static let iconSize: CGFloat = 100
    private static let center = CGPoint(x: 200, y: 200)
    private static let padding: CGFloat = 20
    private static let cornerRadius: CGFloat = 35
    private static let base = RGBColor(red: 0, green: 0.45, blue: 1)

    private static func configuration(background: ItemBackground) -> DMGConfiguration {
        var config = DMGConfiguration()
        config.window = WindowConfiguration(width: canvas.width, height: canvas.height)
        config.iconSize = iconSize
        config.background.type = .color
        config.background.color = base
        config.items = [
            CanvasItem(kind: .app, label: "App.app", position: center, background: background),
        ]
        return config
    }

    private static func panelRect() -> CGRect {
        ItemGeometry.panelRect(center: center, iconSize: iconSize, padding: padding)
    }

    private nonisolated static func shadow(opacity: CGFloat, radius: CGFloat, offsetY: CGFloat) -> ShadowConfiguration {
        var shadow = ShadowConfiguration()
        shadow.opacity = opacity
        shadow.radius = radius
        shadow.offsetX = 0
        shadow.offsetY = offsetY
        return shadow
    }

    /// Reads an image back as straight RGBA8 bytes for pixel-level assertions.
    private static func rgbaBytes(of image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    /// The RGB of one pixel, addressed top-down like the image's own rows.
    private static func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    /// Draws `image` over `base`, the way the canvas layers a panel onto its backdrop.
    private static func compositing(_ image: CGImage, over base: CGImage) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: base.width, height: base.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        ctx.draw(base, in: bounds)
        ctx.draw(image, in: bounds)
        return ctx.makeImage()
    }

    private static func composite(_ config: DMGConfiguration, scale: CGFloat) throws -> CGImage {
        try #require(CompositeRenderer.renderAnalysisComposite(
            configuration: config, layerImages: [:], scale: scale,
        ))
    }

    private static var baseRGB: (r: Int, g: Int, b: Int) {
        (Int((base.red * 255).rounded()), Int((base.green * 255).rounded()), Int((base.blue * 255).rounded()))
    }

    // MARK: - Bevel Shape

    /// The bevel is a soft-light overlay of an opaque square. Drawn unclipped it tints the
    /// panel's whole bounding box, which is what erased the corner radius from built DMGs
    /// while the canvas — which did clip it — kept showing rounded corners.
    @Test
    func `A bevel leaves the background outside the corner radius untouched`() throws {
        let background = ItemBackground(
            enabled: false,
            cornerRadius: Self.cornerRadius,
            padding: Self.padding,
            bevel: BevelConfiguration(enabled: true, depth: 1, lightAngle: 229, intensity: 0.4),
        )
        let image = try Self.composite(Self.configuration(background: background), scale: 1)
        let bytes = Self.rgbaBytes(of: image)
        let rect = Self.panelRect()

        for (dx, dy) in [(2, 2), (2, 182), (182, 2), (182, 182)] {
            let sample = Self.pixel(bytes, width: image.width, x: Int(rect.minX) + dx, y: Int(rect.minY) + dy)
            #expect(sample == Self.baseRGB, "corner offset (\(dx), \(dy)) was tinted by the bevel")
        }
    }

    /// A bevel describes an edge. Its shading response is biased so a surface facing the
    /// viewer reads mid-gray — the identity under soft light — so the flat interior of the
    /// panel comes out exactly as it went in.
    @Test
    func `A bevel leaves the panel's flat interior untouched`() throws {
        let background = ItemBackground(
            enabled: false,
            cornerRadius: Self.cornerRadius,
            padding: Self.padding,
            bevel: BevelConfiguration(enabled: true, depth: 5, lightAngle: 135, intensity: 0.5),
        )
        let image = try Self.composite(Self.configuration(background: background), scale: 1)
        let bytes = Self.rgbaBytes(of: image)

        let sample = Self.pixel(bytes, width: image.width, x: Int(Self.center.x), y: Int(Self.center.y))
        #expect(sample == Self.baseRGB)
    }

    // MARK: - Shadow Scale

    /// Core Graphics reads shadow offsets and blur radii in device space, ignoring the CTM,
    /// so a shadow drawn from the same points lands half as far in the `@2x` representation
    /// unless it is scaled by hand.
    @Test
    func `A panel shadow reaches the same distance at 1x and 2x`() throws {
        let background = ItemBackground(
            enabled: false,
            cornerRadius: Self.cornerRadius,
            padding: Self.padding,
            shadow: Self.shadow(opacity: 0.8, radius: 10, offsetY: 24),
        )
        let config = Self.configuration(background: background)

        func shadowReach(scale: CGFloat) throws -> CGFloat {
            let image = try Self.composite(config, scale: scale)
            let bytes = Self.rgbaBytes(of: image)
            let x = Int(Self.center.x * scale)
            let firstRowBelowPanel = Int(Self.panelRect().maxY * scale) + 1
            var lastShadowRow = firstRowBelowPanel
            for y in firstRowBelowPanel ..< image.height {
                let sample = Self.pixel(bytes, width: image.width, x: x, y: y)
                if abs(sample.b - Self.baseRGB.b) > 2 || abs(sample.g - Self.baseRGB.g) > 2 {
                    lastShadowRow = y
                }
            }
            return (CGFloat(lastShadowRow) - Self.panelRect().maxY * scale) / scale
        }

        let reach1x = try shadowReach(scale: 1)
        let reach2x = try shadowReach(scale: 2)
        #expect(reach1x > 20, "the fixture should cast a shadow well clear of the panel")
        #expect(abs(reach1x - reach2x) <= 1)
    }

    // MARK: - Canvas / Bake Parity

    /// The canvas paints `renderCanvasComposite`; the build bakes `renderBackgroundTIFF`.
    /// Both have to be the same picture, or the editor is promising something the disk
    /// image will not show. This is the guard that made the panel work worth doing.
    @Test
    func `The canvas composite is the baked background`() throws {
        var background = ItemBackground(
            enabled: true, opacity: 0.3, cornerRadius: 22, padding: 16, blurRadius: 34,
        )
        background.shadow = Self.shadow(opacity: 0.4, radius: 14, offsetY: 8)
        background.bevel = BevelConfiguration()

        var config = Self.configuration(background: background)
        config.window = WindowConfiguration(width: 400, height: 400)
        config.background.type = .gradient
        config.background.gradient = GradientConfiguration()
        config.textLayers = [
            TextLayerConfiguration(
                text: "Install", position: CGPoint(x: 200, y: 60), fontSize: 28,
                color: RGBColor(red: 1, green: 1, blue: 1),
            ),
        ]
        // Overlapping panels: the case that broke when panels were composited one by one.
        config.items = [
            CanvasItem(kind: .app, label: "A.app", position: CGPoint(x: 130, y: 150), background: background),
            CanvasItem(kind: .folder, label: "B", position: CGPoint(x: 270, y: 150), background: background),
            CanvasItem(kind: .file, label: "C", position: CGPoint(x: 200, y: 300), background: background),
        ]

        let canvas = try #require(CompositeRenderer.renderCanvasComposite(
            configuration: config, layerImages: [:], scale: 2,
        ))

        let tiff = try #require(CompositeRenderer.renderBackgroundTIFF(
            configuration: config, assetsDirectory: FileManager.default.temporaryDirectory,
        ))
        let reps = try #require(NSBitmapImageRep.imageReps(with: tiff) as? [NSBitmapImageRep])
        let retina = try #require(reps.first { $0.pixelsWide == canvas.width })
        let baked = try #require(retina.cgImage)

        let expected = Self.rgbaBytes(of: baked)
        let actual = Self.rgbaBytes(of: canvas)
        let worst = zip(expected, actual).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst == 0, "the canvas composite differs from the baked background by \(worst)/255")
    }
}
