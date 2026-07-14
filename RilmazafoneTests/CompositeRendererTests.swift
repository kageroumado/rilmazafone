import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Rilmazafone

@Suite("CompositeRenderer")
@MainActor
struct CompositeRendererTests {
    // MARK: - Fixtures

    /// A configuration that exercises a gradient base, a text layer, and an item panel
    /// with a readback gaussian blur — the paths most at risk of nondeterminism.
    static func blurGradientTextConfiguration() -> DMGConfiguration {
        var config = DMGConfiguration()
        config.window = WindowConfiguration(width: 400, height: 300)

        config.background.type = .gradient
        config.background.gradient = GradientConfiguration()

        config.textLayers = [
            TextLayerConfiguration(
                text: "Determinism",
                position: CGPoint(x: 200, y: 80),
                fontSize: 28,
                color: RGBColor(red: 1, green: 1, blue: 1),
            ),
        ]

        config.items = [
            CanvasItem(
                kind: .app,
                label: "App.app",
                position: CGPoint(x: 200, y: 190),
                background: ItemBackground(enabled: true, opacity: 0.3, blurRadius: 18, blurFeather: 0),
            ),
        ]

        return config
    }

    // MARK: - Determinism

    @Test
    func `Rendering the same configuration twice is byte-identical`() throws {
        let config = Self.blurGradientTextConfiguration()
        let assets = FileManager.default.temporaryDirectory

        let first = try #require(CompositeRenderer.renderBackgroundTIFF(configuration: config, assetsDirectory: assets))
        let second = try #require(CompositeRenderer.renderBackgroundTIFF(configuration: config, assetsDirectory: assets))

        #expect(first == second)
    }

    // MARK: - Multi-Representation TIFF

    @Test
    func `Baked TIFF holds exactly a 1x and a 2x representation`() throws {
        let config = Self.blurGradientTextConfiguration()
        let assets = FileManager.default.temporaryDirectory

        let data = try #require(CompositeRenderer.renderBackgroundTIFF(configuration: config, assetsDirectory: assets))
        let reps = NSBitmapImageRep.imageReps(with: data)

        #expect(reps.count == 2)

        let expectedWidth = Int(config.window.width)
        let expectedHeight = Int(config.window.height)

        let pixelWidths = reps.map(\.pixelsWide).sorted()
        let pixelHeights = reps.map(\.pixelsHigh).sorted()
        #expect(pixelWidths == [expectedWidth, expectedWidth * 2])
        #expect(pixelHeights == [expectedHeight, expectedHeight * 2])

        // Both representations report the 1x point size, which is what makes the
        // high-resolution one an `@2x` representation for Finder.
        for rep in reps {
            #expect(rep.size.width == config.window.width)
            #expect(rep.size.height == config.window.height)
        }
    }
}
