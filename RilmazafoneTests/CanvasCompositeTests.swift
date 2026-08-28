import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Rilmazafone

@Suite("Canvas composite")
@MainActor
struct CanvasCompositeTests {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let canvas = CGSize(width: 400, height: 300)
    private static let base = RGBColor(red: 0, green: 0.45, blue: 1)

    private static func configuration() -> DMGConfiguration {
        var config = DMGConfiguration()
        config.window = WindowConfiguration(width: canvas.width, height: canvas.height)
        config.background.type = .color
        config.background.color = base
        config.textLayers = [
            TextLayerConfiguration(
                text: "Install",
                position: CGPoint(x: 200, y: 80),
                fontSize: 32,
                color: RGBColor(red: 1, green: 1, blue: 1),
            ),
        ]
        config.sfSymbolLayers = [
            SFSymbolLayerConfiguration(
                position: CGPoint(x: 200, y: 220),
                symbolName: "arrow.right",
                pointSize: 48,
                color: RGBColor(red: 1, green: 1, blue: 1),
            ),
        ]
        return config
    }

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

    private static func composite(_ config: DMGConfiguration, excluding: UUID?) throws -> CGImage {
        try #require(CompositeRenderer.renderPanelBackdrop(
            configuration: config, layerImages: [:], scale: 2, excluding: excluding,
        ))
    }

    /// The canvas draws the selected layer live so it can be dragged and, for text,
    /// edited — which only works if the composite underneath leaves that one layer out.
    /// Everything else has to come through untouched, or selecting a layer would change
    /// the rest of the picture.
    @Test
    func `Excluding a layer removes it and leaves the rest of the composite alone`() throws {
        let config = Self.configuration()
        let text = config.textLayers[0]
        let symbol = config.sfSymbolLayers[0]

        let full = try Self.rgbaBytes(of: Self.composite(config, excluding: nil))
        let withoutText = try Self.rgbaBytes(of: Self.composite(config, excluding: text.id))
        let withoutSymbol = try Self.rgbaBytes(of: Self.composite(config, excluding: symbol.id))

        #expect(full != withoutText, "excluding the text layer changed nothing")
        #expect(full != withoutSymbol, "excluding the symbol layer changed nothing")

        // The text sits at y = 80 and the symbol at y = 220, so each exclusion may only
        // touch its own band. Compare the other band against the full composite.
        let width = Int(Self.canvas.width * 2)
        func band(_ bytes: [UInt8], rows: Range<Int>) -> ArraySlice<UInt8> {
            bytes[(rows.lowerBound * width * 4) ..< (rows.upperBound * width * 4)]
        }
        #expect(band(withoutText, rows: 380 ..< 500) == band(full, rows: 380 ..< 500))
        #expect(band(withoutSymbol, rows: 40 ..< 200) == band(full, rows: 40 ..< 200))
    }

    /// Excluding an id that matches nothing is the canvas's resting state — no selection.
    @Test
    func `Excluding nothing composites every layer`() throws {
        let config = Self.configuration()
        let none = try Self.rgbaBytes(of: Self.composite(config, excluding: nil))
        let stranger = try Self.rgbaBytes(of: Self.composite(config, excluding: UUID()))
        #expect(none == stranger)
    }
}
