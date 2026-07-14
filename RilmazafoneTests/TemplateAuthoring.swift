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
        try write("Snow Leopard", snowLeopard())
        try write("Cosmos", cosmos())
        try write("Toolbox", toolbox())

        for name in [
            "Snow Leopard", "Cosmos", "Toolbox",
            "Classic", "Graphite", "Aurora", "Editorial", "Glass", "Compact",
        ] {
            report(name)
        }

        if let previewDir = ProcessInfo.processInfo.environment["PREVIEW_DIR"] {
            let base = URL(fileURLWithPath: previewDir)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            for name in ["Snow Leopard", "Cosmos", "Toolbox"] {
                for mode in LabelAppearanceMode.allCases {
                    writePreview(name, mode: mode, into: base)
                }
            }
        }
    }

    // MARK: - Preview render (background + panels + tiles + mode-colored labels)

    private func writePreview(_ name: String, mode: LabelAppearanceMode, into dir: URL) {
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
        let labelColor: NSColor = mode == .dark ? .white : .black
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
        let file = dir.appending(path: "\(name.replacingOccurrences(of: " ", with: "-"))-\(mode.rawValue).png")
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

        let panel = darkGlass(color: RGBColor(red: 0.10, green: 0.11, blue: 0.13), opacity: 0.52, padding: 18)
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
        let panel = coolFrost(color: RGBColor(red: 0.40, green: 0.43, blue: 0.51), opacity: 0.76, padding: 16)
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

        let panel = darkGlass(color: RGBColor(red: 0.12, green: 0.14, blue: 0.18), opacity: 0.6, padding: 16)
        c.items = [
            placeholderApp(position: CGPoint(x: 205, y: 150), panel: panel),
            applications(position: CGPoint(x: 495, y: 150), panel: panel),
            placeholderFolder(position: CGPoint(x: 205, y: 350), panel: panel),
            placeholderFile(position: CGPoint(x: 495, y: 350), panel: panel),
        ]
        c.sfSymbolLayers = [arrow(at: CGPoint(x: 350, y: 142), color: RGBColor(red: 0.28, green: 0.32, blue: 0.4))]
        return c
    }

    // MARK: - Item builders

    private func placeholderApp(position: CGPoint, panel: ItemBackground) -> CanvasItem {
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

    private func applications(position: CGPoint, panel: ItemBackground) -> CanvasItem {
        var item = CanvasItem(kind: .applicationsSymlink, label: "Applications", position: position)
        item.background = panel
        return item
    }

    // MARK: - Panel presets

    private func darkGlass(color: RGBColor, opacity: CGFloat, padding: CGFloat) -> ItemBackground {
        ItemBackground(
            enabled: true, color: color, opacity: opacity,
            cornerRadius: 22, padding: padding, blurRadius: 30, blurFeather: 0,
            blendMode: .normal,
            shadow: shadow(opacity: 0.42, radius: 12, y: 7),
            bevel: BevelConfiguration(enabled: true, depth: 4, lightAngle: 125, intensity: 0.35),
        )
    }

    private func coolFrost(color: RGBColor, opacity: CGFloat, padding: CGFloat) -> ItemBackground {
        ItemBackground(
            enabled: true, color: color, opacity: opacity,
            cornerRadius: 20, padding: padding, blurRadius: 34, blurFeather: 0,
            blendMode: .normal,
            shadow: shadow(opacity: 0.5, radius: 16, y: 8),
            bevel: BevelConfiguration(enabled: true, depth: 4, lightAngle: 120, intensity: 0.3),
        )
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
