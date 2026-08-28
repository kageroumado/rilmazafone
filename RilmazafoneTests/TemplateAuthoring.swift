import AppKit
import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Rilmazafone

/// One-shot authoring harness for the raster-backed bundled templates
/// (Snow Leopard, Cosmos, Toolbox). It builds each `DMGConfiguration` against the
/// real model, generates the Aqua pinstripe asset, writes each `document.json`
/// (pretty-printed, sorted keys — never hand-typed), and then prints, per item,
/// the exact label-zone luminance/contrast the legibility analyzer sees so the
/// panels can be tuned to zero warnings.
///
/// Gated on `GENERATE_TEMPLATES=1` so it never rewrites source files during a
/// normal test run. Invoke explicitly:
///   GENERATE_TEMPLATES=1 xcodebuild ... test \
///     -only-testing:RilmazafoneTests/TemplateAuthoring
@Suite(
    "Template authoring",
    .enabled(if: ProcessInfo.processInfo.environment["GENERATE_TEMPLATES"] == "1"),
)
struct TemplateAuthoring {
    typealias RGBColor = Rilmazafone.RGBColor

    static let templatesDir: URL = .init(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Rilmazafone/Resources/Templates")

    @Test
    func `generate raster-backed templates and report legibility`() throws {
        try writePinstripes()
        try copyRisographSource()

        // Mesh + grain + glass: what a window looks like on macOS 26.
        try write("Aurora", aurora())
        try write("Glass", glass())
        try write("Graphite", graphite())
        try write("Classic", classic())
        try write("Compact", compact())
        try write("Editorial", editorial())

        // Photographs, with the same glass treatment over them.
        try write("Snow Leopard", snowLeopard())
        try write("Cosmos", cosmos())

        // The one retro template. Bevel belongs here and nowhere else now.
        try write("Toolbox", toolbox())

        // The unexpected one.
        try write("Risograph", risograph())

        for name in [
            "Snow Leopard", "Cosmos", "Toolbox", "Risograph",
            "Classic", "Graphite", "Aurora", "Editorial", "Glass", "Compact",
        ] {
            report(name)
        }

        if let previewDir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] {
            let base = URL(fileURLWithPath: previewDir)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            for name in ["Snow Leopard", "Cosmos", "Toolbox"] {
                writePreview(name, into: base)
            }
        }
    }

    // MARK: - Preview render (background + panels + tiles + labels)

    private func writePreview(_ name: String, into dir: URL) {
        let templateDir = Self.templatesDir.appending(path: "\(name).dmgtemplate")
        guard let data = try? Data(contentsOf: templateDir.appending(path: "document.json")),
              var config = try? JSONDecoder().decode(DMGConfiguration.self, from: data) else { return }
        config.expandAbbreviatedPaths()

        var layerImages: [UUID: NSImage] = [:]
        for layer in config.background.layers {
            let url = templateDir.appending(path: "Assets").appending(path: layer.imageName)
            if let image = NSImage(contentsOf: url) { layerImages[layer.id] = image }
        }

        let scale: CGFloat = 2
        guard let composite = CompositeRenderer.renderAnalysisComposite(
            configuration: config, layerImages: layerImages, scale: scale,
        ) else { return }

        let w = composite.width, h = composite.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { return }
        ctx.draw(composite, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        let iconSize = config.iconSize
        let canvasH = config.window.height
        // Finder draws these dark whatever the appearance: a window with a background
        // picture keeps its Light Mode rendering.
        let labelColor: NSColor = .black
        for item in config.items {
            let contentHeight = iconSize + 10 * 2 + 4 + 20
            let iconCenterTop = item.position.y - contentHeight / 2 + 10 + iconSize / 2
            let iconRect = CGRect(
                x: item.position.x - iconSize / 2,
                y: canvasH - iconCenterTop - iconSize / 2,
                width: iconSize, height: iconSize,
            )
            drawTile(for: item, in: iconRect)

            let labelTop = item.position.y - contentHeight / 2 + iconSize + 10 * 2 + 4
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: config.textSize),
                .foregroundColor: labelColor,
            ]
            let text = item.label as NSString
            let size = text.size(withAttributes: attrs)
            let labelY = canvasH - labelTop - size.height
            text.draw(at: CGPoint(x: item.position.x - size.width / 2, y: labelY), withAttributes: attrs)
        }

        NSGraphicsContext.restoreGraphicsState()
        guard let out = ctx.makeImage() else { return }
        let file = dir.appending(path: "\(name.replacingOccurrences(of: " ", with: "-")).png")
        if let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, out, nil)
            CGImageDestinationFinalize(dest)
        }
    }

    private func drawTile(for item: CanvasItem, in rect: CGRect) {
        if item.isPlaceholder {
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2, yRadius: rect.width * 0.2)
            path.lineWidth = 2
            NSColor(white: 0.85, alpha: 0.7).setStroke()
            let dash: [CGFloat] = [6, 4]
            path.setLineDash(dash, count: 2, phase: 0)
            path.stroke()
            if let glyph = NSImage(systemSymbolName: item.placeholderGlyphName, accessibilityDescription: nil) {
                let inset = rect.width * 0.26
                let gRect = rect.insetBy(dx: inset, dy: inset)
                glyph.isTemplate = true
                NSColor(white: 0.9, alpha: 0.75).set()
                glyph.draw(in: gRect)
            }
        } else if let icon = CanvasItem.resolveIcon(for: item, documentURL: nil) {
            icon.draw(in: rect)
        }
    }

    // MARK: - Snow Leopard (2 elements, CC0 photo)

    private func snowLeopard() -> DMGConfiguration {
        var c = DMGConfiguration()
        c.volumeName = "Snow Leopard"
        c.window = WindowConfiguration(width: 660, height: 430)
        c.iconSize = 128
        c.textSize = 13
        c.background.type = .image
        c.background.color = RGBColor(red: 0.86, green: 0.88, blue: 0.9)
        c.background.layers = [fullBleedLayer(imageName: "snow-leopard.jpg", label: "Snow leopard", window: c.window)]

        let panel = liquidGlass(padding: 18)
        c.items = [
            placeholderApp(position: CGPoint(x: 195, y: 312), panel: panel),
            applications(position: CGPoint(x: 465, y: 312), panel: panel),
        ]
        c.sfSymbolLayers = [arrow(at: CGPoint(x: 330, y: 304), color: RGBColor(red: 0.95, green: 0.96, blue: 0.98))]
        return c
    }

    // MARK: - Cosmos (3 elements, NASA aurora)

    private func cosmos() -> DMGConfiguration {
        var c = DMGConfiguration()
        c.volumeName = "Cosmos"
        // Window aspect (≈1.51) tracks the aurora's (1800×1197) so it covers at
        // scale 1, and the extra height lets the Read Me slot clear both top
        // panels with a comfortable gap.
        c.window = WindowConfiguration(width: 740, height: 490)
        c.iconSize = 112
        c.textSize = 13
        c.background.type = .image
        c.background.color = RGBColor(red: 0.02, green: 0.02, blue: 0.05)
        var aurora = fullBleedLayer(imageName: "aurora.jpg", label: "Aurora from orbit", window: c.window)
        aurora.colorAdjustments = ColorAdjustments(brightness: -0.06, contrast: 1.02, saturation: 1.05, hueRotation: 0, exposure: 0)
        c.background.layers = [aurora]

        // Inverted triangle: two-panel install row up top, Read Me centered below
        // with a clear vertical gap (no panel overlaps another).
        c.background.grain = grain(0.018)

        let panel = liquidGlass(padding: 16)
        c.items = [
            placeholderApp(position: CGPoint(x: 210, y: 170), panel: panel),
            applications(position: CGPoint(x: 530, y: 170), panel: panel),
            placeholderFile(position: CGPoint(x: 370, y: 372), panel: panel),
        ]
        c.sfSymbolLayers = [arrow(at: CGPoint(x: 370, y: 160), color: RGBColor(red: 0.85, green: 0.92, blue: 0.88))]
        return c
    }

    // MARK: - Toolbox (4 elements, Aqua pinstripes)

    private func toolbox() -> DMGConfiguration {
        var c = DMGConfiguration()
        c.volumeName = "Installer"
        c.window = WindowConfiguration(width: 700, height: 500)
        c.iconSize = 112
        c.textSize = 13
        c.background.type = .image
        c.background.color = RGBColor(red: 0.90, green: 0.92, blue: 0.95)
        c.background.layers = [fullBleedLayer(imageName: "aqua-pinstripes.png", label: "Aqua pinstripes", window: c.window)]

        let panel = embossed(color: RGBColor(red: 0.96, green: 0.97, blue: 0.99), opacity: 0.82, padding: 16)
        c.items = [
            placeholderApp(position: CGPoint(x: 205, y: 150), panel: panel),
            applications(position: CGPoint(x: 495, y: 150), panel: panel),
            placeholderFolder(position: CGPoint(x: 205, y: 350), panel: panel),
            placeholderFile(position: CGPoint(x: 495, y: 350), panel: panel),
        ]
        c.sfSymbolLayers = [arrow(at: CGPoint(x: 350, y: 142), color: RGBColor(red: 0.28, green: 0.32, blue: 0.4))]
        // No grain: the pinstripes are the texture, and 2003 had no dither to spare.
        return c
    }

    // MARK: - Modern templates

    /// Violet through magenta to amber, the palette the mesh editor opens on.
    private func aurora() -> DMGConfiguration {
        var c = DMGConfiguration()
        c.volumeName = "Install"
        c.window = WindowConfiguration(width: 660, height: 430)
        c.iconSize = 128
        c.textSize = 13
        c.background.type = .mesh
        // The top row carries the title, so it stays dark enough to hold white type.
        c.background.mesh = mesh([
            [rgb(0.20, 0.10, 0.36), rgb(0.31, 0.13, 0.46), rgb(0.44, 0.17, 0.47)],
            [rgb(0.45, 0.22, 0.60), rgb(0.72, 0.37, 0.60), rgb(0.92, 0.50, 0.53)],
            [rgb(0.72, 0.35, 0.58), rgb(0.95, 0.59, 0.48), rgb(0.99, 0.77, 0.50)],
        ])
        c.background.grain = grain(0.020)

        let panel = liquidGlass(padding: 18)
        c.items = [
            placeholderApp(position: CGPoint(x: 195, y: 300), panel: panel),
            applications(position: CGPoint(x: 465, y: 300), panel: panel),
        ]
        c.textLayers = [title("Drag to Install", at: CGPoint(x: 330, y: 84), size: 30, color: rgb(1, 1, 1))]
        c.sfSymbolLayers = [arrow(at: CGPoint(x: 330, y: 292), color: rgb(1, 1, 1))]
        return c
    }

    /// Cool and bright — the palest of the set, and the one that shows the glass
    /// rim most clearly.
    private func glass() -> DMGConfiguration {
        var c = DMGConfiguration()
        c.volumeName = "Install"
        c.window = WindowConfiguration(width: 660, height: 400)
        c.iconSize = 128
        c.textSize = 13
        c.background.type = .mesh
        c.background.mesh = mesh([
            [rgb(0.16, 0.35, 0.62), rgb(0.22, 0.50, 0.76), rgb(0.35, 0.66, 0.86)],
            [rgb(0.26, 0.52, 0.78), rgb(0.46, 0.71, 0.89), rgb(0.66, 0.84, 0.94)],
            [rgb(0.42, 0.68, 0.86), rgb(0.68, 0.85, 0.94), rgb(0.86, 0.94, 0.98)],
        ])
        c.background.grain = grain(0.016)

        let panel = liquidGlass(padding: 18)
        c.items = [
            placeholderApp(position: CGPoint(x: 195, y: 232), panel: panel),
            applications(position: CGPoint(x: 465, y: 232), panel: panel),
        ]
        c.sfSymbolLayers = [arrow(at: CGPoint(x: 330, y: 224), color: rgb(1, 1, 1))]
        return c
    }

    /// Near-monochrome and dark, to show light glass carrying dark labels over a
    /// dark ground — the combination Finder actually renders.
    private func graphite() -> DMGConfiguration {
        var c = DMGConfiguration()
        c.volumeName = "Install"
        c.window = WindowConfiguration(width: 640, height: 400)
        c.iconSize = 120
        c.textSize = 13
        c.background.type = .mesh
        c.background.mesh = mesh([
            [rgb(0.10, 0.11, 0.13), rgb(0.15, 0.16, 0.19), rgb(0.11, 0.12, 0.15)],
            [rgb(0.16, 0.17, 0.21), rgb(0.24, 0.26, 0.31), rgb(0.17, 0.19, 0.23)],
            [rgb(0.12, 0.13, 0.16), rgb(0.18, 0.20, 0.24), rgb(0.13, 0.14, 0.17)],
        ])
        c.background.grain = grain(0.024)

        let panel = liquidGlass(padding: 16, opacity: 0.68)
        c.items = [
            placeholderApp(position: CGPoint(x: 190, y: 232), panel: panel),
            applications(position: CGPoint(x: 450, y: 232), panel: panel),
        ]
        c.sfSymbolLayers = [arrow(at: CGPoint(x: 320, y: 224), color: rgb(0.78, 0.80, 0.85))]
        return c
    }

    /// The restrained default: a pale ground, no panels, nothing to explain.
    private func classic() -> DMGConfiguration {
        var c = DMGConfiguration()
        c.volumeName = "Install"
        c.window = WindowConfiguration(width: 660, height: 400)
        c.iconSize = 128
        c.textSize = 13
        c.background.type = .mesh
        // Deep enough that white glass reads against it — most installers are light,
        // and this is the one that shows what a panel does there.
        c.background.mesh = mesh([
            [rgb(0.83, 0.86, 0.91), rgb(0.79, 0.83, 0.89), rgb(0.74, 0.79, 0.86)],
            [rgb(0.79, 0.83, 0.89), rgb(0.74, 0.79, 0.86), rgb(0.69, 0.75, 0.83)],
            [rgb(0.74, 0.79, 0.86), rgb(0.69, 0.75, 0.83), rgb(0.63, 0.70, 0.80)],
        ])
        c.background.grain = grain(0.014)

        let panel = liquidGlass(padding: 18, opacity: 0.62)
        c.items = [
            placeholderApp(position: CGPoint(x: 195, y: 220), panel: panel),
            applications(position: CGPoint(x: 465, y: 220), panel: panel),
        ]
        c.sfSymbolLayers = [arrow(at: CGPoint(x: 330, y: 212), color: rgb(0.34, 0.38, 0.46))]
        return c
    }

    /// Small window, one row, nothing else.
    private func compact() -> DMGConfiguration {
        var c = DMGConfiguration()
        c.volumeName = "Install"
        c.window = WindowConfiguration(width: 500, height: 340)
        c.iconSize = 96
        c.textSize = 12
        c.background.type = .mesh
        // Warm and bare — the small, quiet one, and visibly not Classic at another size.
        c.background.mesh = mesh([
            [rgb(0.97, 0.95, 0.92), rgb(0.96, 0.93, 0.89), rgb(0.94, 0.90, 0.85)],
            [rgb(0.96, 0.93, 0.89), rgb(0.94, 0.90, 0.85), rgb(0.91, 0.87, 0.81)],
            [rgb(0.94, 0.90, 0.85), rgb(0.91, 0.87, 0.81), rgb(0.88, 0.83, 0.77)],
        ])
        c.background.grain = grain(0.014)

        c.items = [
            placeholderApp(position: CGPoint(x: 145, y: 185)),
            applications(position: CGPoint(x: 355, y: 185)),
        ]
        c.sfSymbolLayers = [arrow(at: CGPoint(x: 250, y: 178), color: rgb(0.52, 0.45, 0.37))]
        return c
    }

    /// Type-led: a warm ground, a title, and room around everything.
    private func editorial() -> DMGConfiguration {
        var c = DMGConfiguration()
        c.volumeName = "Install"
        c.window = WindowConfiguration(width: 720, height: 460)
        c.iconSize = 120
        c.textSize = 13
        c.background.type = .mesh
        c.background.mesh = mesh([
            [rgb(0.98, 0.96, 0.92), rgb(0.97, 0.94, 0.89), rgb(0.95, 0.91, 0.85)],
            [rgb(0.97, 0.94, 0.89), rgb(0.95, 0.91, 0.85), rgb(0.92, 0.87, 0.80)],
            [rgb(0.95, 0.92, 0.86), rgb(0.92, 0.88, 0.81), rgb(0.88, 0.83, 0.75)],
        ])
        c.background.grain = grain(0.018)

        c.textLayers = [
            title("Your App", at: CGPoint(x: 360, y: 96), size: 38, color: rgb(0.16, 0.13, 0.10)),
            body("Drag it into Applications to install.", at: CGPoint(x: 360, y: 138), color: rgb(0.42, 0.37, 0.31)),
        ]
        c.items = [
            placeholderApp(position: CGPoint(x: 235, y: 296)),
            applications(position: CGPoint(x: 485, y: 296)),
        ]
        c.sfSymbolLayers = [arrow(at: CGPoint(x: 360, y: 288), color: rgb(0.55, 0.48, 0.40))]
        return c
    }

    // MARK: - Risograph (the unexpected one)

    /// A duotone print: the aurora photograph pushed through a gradient map into
    /// two inks, with grain heavy enough to read as paper rather than as noise.
    /// The one template that uses neither a ramp nor the photograph's own colors.
    private func risograph() -> DMGConfiguration {
        var c = DMGConfiguration()
        c.volumeName = "Install"
        c.window = WindowConfiguration(width: 680, height: 440)
        c.iconSize = 120
        c.textSize = 13
        c.background.type = .image
        c.background.color = rgb(0.96, 0.95, 0.92)

        var ink = fullBleedLayer(imageName: "aurora.jpg", label: "Duotone plate", window: c.window)
        var map = GradientMapConfiguration()
        map.stops = [
            GradientStop(color: rgb(0.09, 0.13, 0.42), location: 0),
            GradientStop(color: rgb(0.98, 0.35, 0.38), location: 0.62),
            GradientStop(color: rgb(0.99, 0.94, 0.86), location: 1),
        ]
        ink.gradientMap = map
        ink.colorAdjustments = ColorAdjustments(
            brightness: 0.02, contrast: 1.18, saturation: 1, hueRotation: 0, exposure: 0,
        )
        c.background.layers = [ink]

        // Coarse and colored: the misregistered ink of a risograph, not a dither.
        var paper = GrainConfiguration()
        paper.amount = 0.10
        paper.size = 1.6
        paper.isColored = true
        c.background.grain = paper

        // Flat paper panels — no blur, no glass. A print has no depth.
        var panel = ItemBackground(
            enabled: true, color: rgb(0.99, 0.97, 0.93), opacity: 0.92,
            cornerRadius: 6, padding: 16, blurRadius: 0, blurFeather: 0, blendMode: .normal,
        )
        panel.shadow = shadow(opacity: 0.22, radius: 2, y: 2)

        c.items = [
            placeholderApp(position: CGPoint(x: 200, y: 286), panel: panel),
            applications(position: CGPoint(x: 480, y: 286), panel: panel),
        ]
        c.textLayers = [
            title("YOUR APP", at: CGPoint(x: 340, y: 86), size: 34, color: rgb(0.99, 0.94, 0.86)),
        ]
        c.sfSymbolLayers = [arrow(at: CGPoint(x: 340, y: 278), color: rgb(0.99, 0.94, 0.86))]
        return c
    }

    // MARK: - Item builders

    private func placeholderApp(position: CGPoint, panel: ItemBackground? = nil) -> CanvasItem {
        var item = CanvasItem.appPlaceholder(position: position)
        item.background = panel
        return item
    }

    private func placeholderFolder(position: CGPoint, panel: ItemBackground) -> CanvasItem {
        var item = CanvasItem.folderPlaceholder(position: position)
        item.background = panel
        return item
    }

    private func placeholderFile(position: CGPoint, panel: ItemBackground) -> CanvasItem {
        var item = CanvasItem.filePlaceholder(position: position)
        item.background = panel
        return item
    }

    private func applications(position: CGPoint, panel: ItemBackground? = nil) -> CanvasItem {
        var item = CanvasItem(kind: .applicationsSymlink, label: "Applications", position: position)
        item.background = panel
        return item
    }

    // MARK: - Panel presets

    /// The modern panel: light, translucent, lit along its top rim, shadowed under
    /// the opposite edge.
    ///
    /// Light rather than dark on purpose. Finder draws icon labels dark whatever the
    /// system appearance — a window with a background picture keeps its Light Mode
    /// rendering — so the panel behind a label has to raise the ground under it, not
    /// lower it.
    private func liquidGlass(padding: CGFloat, opacity: CGFloat = 0.58) -> ItemBackground {
        var panel = ItemBackground(
            enabled: true, color: RGBColor(red: 1, green: 1, blue: 1), opacity: opacity,
            cornerRadius: 24, padding: padding, blurRadius: 30, blurFeather: 0,
            blendMode: .normal,
        )
        panel.shadow = shadow(opacity: 0.28, radius: 16, y: 8)
        var glass = GlassConfiguration()
        glass.borderWidth = 1
        glass.borderOpacity = 0.6
        glass.lightAngle = 105
        glass.innerShadowRadius = 14
        glass.innerShadowOpacity = 0.14
        glass.saturation = 1.25
        panel.glass = glass
        return panel
    }

    /// The retro panel, kept for Toolbox alone: an embossed edge, which is what a
    /// raised surface looked like before glass.
    private func embossed(color: RGBColor, opacity: CGFloat, padding: CGFloat) -> ItemBackground {
        ItemBackground(
            enabled: true, color: color, opacity: opacity,
            cornerRadius: 10, padding: padding, blurRadius: 0, blurFeather: 0,
            blendMode: .normal,
            shadow: shadow(opacity: 0.3, radius: 6, y: 3),
            bevel: BevelConfiguration(enabled: true, depth: 5, lightAngle: 120, intensity: 0.55),
        )
    }

    private func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> RGBColor {
        RGBColor(red: r, green: g, blue: b)
    }

    /// A three-by-three mesh from a row-major palette.
    private func mesh(_ palette: [[RGBColor]]) -> MeshGradientConfiguration {
        var config = MeshGradientConfiguration()
        config.columns = palette.first?.count ?? 3
        config.rows = palette.count
        config.points = palette.flatMap { $0 }.map { MeshControlPoint(color: $0) }
        config.smoothsColors = true
        return config
    }

    /// Enough grain to break the banding an 8-bit mesh shows across a window this
    /// size, and not enough to read as texture.
    private func grain(_ amount: CGFloat) -> GrainConfiguration {
        var grain = GrainConfiguration()
        grain.amount = amount
        grain.size = 1
        grain.isColored = false
        return grain
    }

    private func title(_ text: String, at position: CGPoint, size: CGFloat, color: RGBColor) -> TextLayerConfiguration {
        TextLayerConfiguration(
            text: text, position: position, fontSize: size, isBold: true, color: color,
        )
    }

    private func body(_ text: String, at position: CGPoint, color: RGBColor) -> TextLayerConfiguration {
        TextLayerConfiguration(text: text, position: position, fontSize: 15, color: color)
    }

    /// Risograph prints the same photograph Cosmos does, so it gets its own copy.
    private func copyRisographSource() throws {
        let source = Self.templatesDir.appending(path: "Cosmos.dmgtemplate/Assets/aurora.jpg")
        let assets = Self.templatesDir.appending(path: "Risograph.dmgtemplate/Assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let destination = assets.appending(path: "aurora.jpg")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func shadow(opacity: CGFloat, radius: CGFloat, y: CGFloat) -> ShadowConfiguration {
        var s = ShadowConfiguration()
        s.enabled = true
        s.color = RGBColor(red: 0, green: 0, blue: 0)
        s.opacity = opacity
        s.radius = radius
        s.offsetX = 0
        s.offsetY = y
        return s
    }

    // MARK: - Layer / symbol builders

    private func fullBleedLayer(imageName: String, label: String, window: WindowConfiguration) -> BackgroundLayer {
        BackgroundLayer(
            imageName: imageName,
            label: label,
            position: CGPoint(x: window.width / 2, y: window.height / 2),
            scale: 1.0,
        )
    }

    private func arrow(at position: CGPoint, color: RGBColor) -> SFSymbolLayerConfiguration {
        SFSymbolLayerConfiguration(
            position: position,
            symbolName: "arrow.right",
            pointSize: 34,
            weight: .semibold,
            color: color,
        )
    }

    // MARK: - Aqua pinstripes asset

    /// Draws a subtle early-2000s Aqua horizontal pinstripe field (our own
    /// artwork — no licensing) at 2× the Toolbox window and writes it as a small
    /// PNG. Pale blue-gray base with 1-pt lighter stripes every 4 pt, very low
    /// contrast so it reads as texture, not lines.
    private func writePinstripes() throws {
        let pointWidth = 700, pointHeight = 500
        let scale = 2
        let w = pointWidth * scale, h = pointHeight * scale
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        ) else { throw AuthoringError.context }

        ctx.setFillColor(CGColor(srgbRed: 0.905, green: 0.925, blue: 0.955, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Lighter stripe every 4 pt (8 px), 1 pt (2 px) tall.
        ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.972, blue: 0.99, alpha: 1))
        let period = 4 * scale
        let stripe = 1 * scale
        var y = 0
        while y < h {
            ctx.fill(CGRect(x: 0, y: y, width: w, height: stripe))
            y += period
        }

        guard let image = ctx.makeImage() else { throw AuthoringError.context }
        let assets = Self.templatesDir.appending(path: "Toolbox.dmgtemplate/Assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let out = assets.appending(path: "aqua-pinstripes.png")
        guard let dest = CGImageDestinationCreateWithURL(
            out as CFURL, UTType.png.identifier as CFString, 1, nil,
        ) else { throw AuthoringError.context }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw AuthoringError.context }
    }

    enum AuthoringError: Error { case context }

    // MARK: - Write

    private func write(_ name: String, _ config: DMGConfiguration) throws {
        var portable = config
        portable.abbreviatePaths()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(portable)
        let dir = Self.templatesDir.appending(path: "\(name).dmgtemplate")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appending(path: "document.json"))
    }

    // MARK: - Legibility report

    private func report(_ name: String) {
        let dir = Self.templatesDir.appending(path: "\(name).dmgtemplate")
        guard let data = try? Data(contentsOf: dir.appending(path: "document.json")),
              var config = try? JSONDecoder().decode(DMGConfiguration.self, from: data)
        else { print("REPORT \(name): unreadable"); return }
        config.expandAbbreviatedPaths()

        var layerImages: [UUID: NSImage] = [:]
        for layer in config.background.layers {
            let url = dir.appending(path: "Assets").appending(path: layer.imageName)
            if let image = NSImage(contentsOf: url) { layerImages[layer.id] = image }
        }

        let warnings = LabelContrastAnalyzer.analyze(
            input: LegibilityAnalysisInput(configuration: config, layerImages: layerImages),
        )

        print("REPORT \(name): \(warnings.isEmpty ? "OK (0 warnings)" : "❌ \(warnings.count) warnings")")

        guard let composite = CompositeRenderer.renderAnalysisComposite(
            configuration: config, layerImages: layerImages, scale: 2,
        ), let buffer = LabelContrastAnalyzer.PixelBuffer(normalizing: composite) else { return }
        let scale = CGFloat(composite.width) / config.window.width

        for item in config.items {
            let rect = LabelContrastAnalyzer.labelRect(
                position: item.position, iconSize: config.iconSize, textSize: config.textSize,
            )
            let pr = rect.applying(CGAffineTransform(scaleX: scale, y: scale)).integral
            guard let s = buffer.luminanceStatistics(in: pr) else { continue }
            let thr = LabelContrastAnalyzer.effectiveThreshold(stddev: s.light.stddev)
            let rLight = LabelContrastAnalyzer.contrastRatio(s.light.mean, 0)
            let rDark = LabelContrastAnalyzer.contrastRatio(s.dark.mean, 1)
            let flagL = rLight < thr ? " LIGHT<thr" : ""
            let flagD = rDark < LabelContrastAnalyzer.effectiveThreshold(stddev: s.dark.stddev) ? " DARK<thr" : ""
            print(String(
                format: "   %-14@ L=%.3f sd=%.3f thr=%.2f | light %.2f dark %.2f%@%@",
                item.label as NSString, s.light.mean, s.light.stddev, thr, rLight, rDark, flagL as NSString, flagD as NSString,
            ))
        }
    }
}
