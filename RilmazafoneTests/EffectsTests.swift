import AppKit
import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Rilmazafone

@Suite("Background effects")
@MainActor
struct EffectsTests {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let canvas = CGSize(width: 200, height: 160)

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

    private static func pixel(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    private static func composite(_ config: DMGConfiguration, scale: CGFloat = 1) throws -> CGImage {
        try #require(CompositeRenderer.renderAnalysisComposite(
            configuration: config, layerImages: [:], scale: scale,
        ))
    }

    private static func baseConfiguration() -> DMGConfiguration {
        var config = DMGConfiguration()
        config.window = WindowConfiguration(width: canvas.width, height: canvas.height)
        config.background.type = .color
        config.background.color = RGBColor(red: 0.5, green: 0.5, blue: 0.5)
        return config
    }

    // MARK: - Grain

    /// The baked background is guaranteed byte-identical across machines and rebuilds, so
    /// grain has to come from a seeded generator rather than the system's.
    @Test
    func `Grain is the same speckle on every render`() throws {
        var config = Self.baseConfiguration()
        config.background.grain = GrainConfiguration()

        let first = try Self.rgbaBytes(of: Self.composite(config))
        let second = try Self.rgbaBytes(of: Self.composite(config))
        #expect(first == second)
    }

    @Test
    func `Grain perturbs the background it lies over`() throws {
        let plain = try Self.rgbaBytes(of: Self.composite(Self.baseConfiguration()))

        var config = Self.baseConfiguration()
        var grain = GrainConfiguration()
        grain.amount = 0.1
        config.background.grain = grain
        let grained = try Self.rgbaBytes(of: Self.composite(config))

        #expect(plain != grained)

        // Grain is signed: it should move pixels both ways around the flat gray it lies
        // over, not just darken or just lighten.
        let width = Int(Self.canvas.width)
        var lighter = 0
        var darker = 0
        for y in 0 ..< Int(Self.canvas.height) {
            for x in 0 ..< width {
                let value = Self.pixel(grained, width: width, x: x, y: y).r
                if value > 128 {
                    lighter += 1
                }
                if value < 128 {
                    darker += 1
                }
            }
        }
        #expect(lighter > 0)
        #expect(darker > 0)
    }

    @Test
    func `Grain at zero amount produces no overlay`() {
        var grain = GrainConfiguration()
        grain.amount = 0
        #expect(CompositeRenderer.renderGrainImage(grain: grain, pointSize: Self.canvas, scale: 1) == nil)

        var disabled = GrainConfiguration()
        disabled.enabled = false
        #expect(CompositeRenderer.renderGrainImage(grain: disabled, pointSize: Self.canvas, scale: 1) == nil)
    }

    // MARK: - Mesh Gradient

    /// The corners of a mesh are its corner control points — the one place the surface is
    /// pinned exactly, and the check that the parameter square is not flipped or
    /// transposed on its way to pixels. A corner pixel samples just inside the corner
    /// rather than exactly on it, so it lands within a step or two of the pinned color.
    @Test
    func `A mesh gradient pins its corner colors`() throws {
        var mesh = MeshGradientConfiguration()
        mesh.columns = 2
        mesh.rows = 2
        mesh.points = [
            MeshControlPoint(color: RGBColor(red: 1, green: 0, blue: 0)),
            MeshControlPoint(color: RGBColor(red: 0, green: 1, blue: 0)),
            MeshControlPoint(color: RGBColor(red: 0, green: 0, blue: 1)),
            MeshControlPoint(color: RGBColor(red: 1, green: 1, blue: 0)),
        ]

        var config = Self.baseConfiguration()
        config.background.type = .mesh
        config.background.mesh = mesh

        let image = try Self.composite(config)
        let bytes = Self.rgbaBytes(of: image)
        let width = image.width
        let maxX = width - 1
        let maxY = image.height - 1

        func expectCorner(x: Int, y: Int, isNear expected: (r: Int, g: Int, b: Int)) {
            let corner = Self.pixel(bytes, width: width, x: x, y: y)
            let drift = max(abs(corner.r - expected.r), max(abs(corner.g - expected.g), abs(corner.b - expected.b)))
            #expect(drift <= 2, "corner (\(x), \(y)) was \(corner), expected near \(expected)")
        }

        expectCorner(x: 0, y: 0, isNear: (255, 0, 0))
        expectCorner(x: maxX, y: 0, isNear: (0, 255, 0))
        expectCorner(x: 0, y: maxY, isNear: (0, 0, 255))
        expectCorner(x: maxX, y: maxY, isNear: (255, 255, 0))
    }

    @Test
    func `A mesh gradient paints every pixel`() throws {
        var config = Self.baseConfiguration()
        config.background.type = .mesh
        config.background.mesh = MeshGradientConfiguration()

        let image = try Self.composite(config, scale: 2)
        let bytes = Self.rgbaBytes(of: image)
        // The base fill under the mesh is flat gray; a hole would leave that showing.
        let gray = (r: 128, g: 128, b: 128)
        var holes = 0
        for y in 0 ..< image.height {
            for x in 0 ..< image.width where Self.pixel(bytes, width: image.width, x: x, y: y) == gray {
                holes += 1
            }
        }
        #expect(holes == 0)
    }

    /// A window-sized mesh is re-rasterized on every background edit and again on every
    /// build, so it has to stay well inside a frame even in a debug build.
    @Test
    func `A window-sized mesh rasterizes quickly`() throws {
        let mesh = MeshGradientConfiguration()
        _ = CompositeRenderer.renderMeshImage(mesh: mesh, pixelsWide: 64, pixelsHigh: 64)

        let started = Date()
        _ = try #require(CompositeRenderer.renderMeshImage(mesh: mesh, pixelsWide: 1_320, pixelsHigh: 800))
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 0.5, "a 1320x800 mesh took \(Int(elapsed * 1_000)) ms")
    }

    /// Resizing re-samples the mesh through the same surface the renderer draws, so the
    /// look survives a grid change instead of resetting.
    @Test
    func `Resizing a mesh keeps its corner colors`() {
        let mesh = MeshGradientConfiguration()
        let resized = mesh.resized(columns: 5, rows: 4)

        #expect(resized.columns == 5)
        #expect(resized.rows == 4)
        #expect(resized.points.count == 20)
        #expect(resized.point(column: 0, row: 0)?.color == mesh.point(column: 0, row: 0)?.color)
        #expect(resized.point(column: 4, row: 3)?.color == mesh.point(column: 2, row: 2)?.color)
    }

    // MARK: - Gradient Map

    @Test
    func `A gradient map sends black to the first stop and white to the last`() throws {
        var config = GradientMapConfiguration()
        config.stops = [
            GradientStop(color: RGBColor(red: 1, green: 0, blue: 0), location: 0),
            GradientStop(color: RGBColor(red: 0, green: 0, blue: 1), location: 1),
        ]

        let ramp = try CIImage(cgImage: #require(CompositeRenderer.gradientRampImage(stops: [
            GradientStop(color: RGBColor(red: 0, green: 0, blue: 0), location: 0),
            GradientStop(color: RGBColor(red: 1, green: 1, blue: 1), location: 1),
        ])))

        let mapped = CompositeRenderer.applyGradientMap(to: ramp, config: config)
        let context = CIContext(options: [.useSoftwareRenderer: true, .workingColorSpace: Self.sRGB, .outputColorSpace: Self.sRGB])
        let image = try #require(context.createCGImage(mapped, from: ramp.extent))
        let bytes = Self.rgbaBytes(of: image)

        let dark = Self.pixel(bytes, width: image.width, x: 0, y: 0)
        let light = Self.pixel(bytes, width: image.width, x: image.width - 1, y: 0)
        #expect(dark.r > 200 && dark.b < 60)
        #expect(light.b > 200 && light.r < 60)
    }

    @Test
    func `A gradient map at zero amount leaves the image alone`() {
        var config = GradientMapConfiguration()
        config.amount = 0
        let source = CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.4))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        #expect(CompositeRenderer.applyGradientMap(to: source, config: config) == source)
    }

    // MARK: - Glass

    /// The glass rim is brightest on the lit side and pools shadow under the far one, so
    /// the two edges have to differ — that difference is the whole effect.
    @Test
    func `A glass edge lights one rim and shades the opposite one`() throws {
        var glass = GlassConfiguration()
        glass.lightAngle = 90
        glass.borderWidth = 2
        glass.borderOpacity = 1
        glass.innerShadowOpacity = 0.6
        glass.innerShadowRadius = 10

        var config = Self.baseConfiguration()
        config.iconSize = 40
        let background = ItemBackground(
            enabled: false, cornerRadius: 12, padding: 10, glass: glass,
        )
        config.items = [
            CanvasItem(kind: .app, label: "App.app", position: CGPoint(x: 100, y: 80), background: background),
        ]

        let image = try Self.composite(config)
        let bytes = Self.rgbaBytes(of: image)
        let rect = ItemGeometry.panelRect(center: CGPoint(x: 100, y: 80), iconSize: 40, padding: 10)

        // `lightAngle` 90 points along +y in the renderer's y-up space, which is the top
        // of the finished image — where rows are counted downward from.
        let litEdge = Self.pixel(bytes, width: image.width, x: 100, y: Int(rect.minY) + 1)
        let shadedEdge = Self.pixel(bytes, width: image.width, x: 100, y: Int(rect.maxY) - 1)
        #expect(litEdge.r > shadedEdge.r, "the lit rim should be brighter than the shaded one")
    }

    // MARK: - Build Coverage

    /// Every effect that can only be shown through a baked picture has to make the build
    /// render one. A new effect missing from here builds a DMG without it.
    @Test
    func `Effects that need a baked background ask for one`() {
        var config = Self.baseConfiguration()
        #expect(!config.needsCompositeBackground)

        config.background.grain = GrainConfiguration()
        #expect(config.needsCompositeBackground)

        config.background.grain = nil
        config.background.type = .mesh
        config.background.mesh = MeshGradientConfiguration()
        #expect(config.needsCompositeBackground)
    }
}
