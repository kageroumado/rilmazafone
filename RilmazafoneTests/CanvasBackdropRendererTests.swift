import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Rilmazafone

@Suite("CanvasBackdropRenderer")
@MainActor
struct CanvasBackdropRendererTests {
    // MARK: - Fixtures

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func makeContext(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
        )!
    }

    /// Horizontal black-to-white gradient at 2x pixel density for a given point size.
    private static func gradientImage(pointSize: CGSize, scale: CGFloat = 2) -> CGImage {
        let width = Int(pointSize.width * scale)
        let height = Int(pointSize.height * scale)
        let ctx = makeContext(width: width, height: height)
        let gradient = CGGradient(
            colorsSpace: sRGB,
            colors: [
                CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
                CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            ] as CFArray,
            locations: [0, 1],
        )!
        ctx.drawLinearGradient(
            gradient,
            start: .zero,
            end: CGPoint(x: width, y: 0),
            options: [],
        )
        return ctx.makeImage()!
    }

    /// High-frequency checkerboard so a Gaussian blur measurably changes the pixels.
    private static func checkerboardImage(pointSize: CGSize, scale: CGFloat = 2) -> CGImage {
        let width = Int(pointSize.width * scale)
        let height = Int(pointSize.height * scale)
        let square = 4
        let ctx = makeContext(width: width, height: height)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        for row in 0 ..< (height / square + 1) {
            for col in 0 ..< (width / square + 1) where (row + col).isMultiple(of: 2) {
                ctx.fill(CGRect(x: col * square, y: row * square, width: square, height: square))
            }
        }
        return ctx.makeImage()!
    }

    private static func solidImage(pointSize: CGSize, gray: CGFloat, scale: CGFloat = 2) -> CGImage {
        let width = Int(pointSize.width * scale)
        let height = Int(pointSize.height * scale)
        let ctx = makeContext(width: width, height: height)
        // Fill in sRGB explicitly; CGColor(gray:) is generic gray gamma 2.2 and would
        // land on different sRGB byte values than the assertion expects.
        ctx.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// Reads an image back as straight RGBA8 bytes for pixel-level assertions.
    private static func rgbaBytes(of image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    // MARK: - Geometry

    @Test
    func `Blurred crop has the panel rect's pixel dimensions`() throws {
        let pointSize = CGSize(width: 400, height: 300)
        let backdrop = Self.gradientImage(pointSize: pointSize)

        let output = try #require(CanvasBackdropRenderer.blurredCrop(
            from: backdrop,
            backdropPointSize: pointSize,
            rect: CGRect(x: 60, y: 40, width: 120, height: 90),
            blurRadius: 10,
        ))

        #expect(output.width == 240)
        #expect(output.height == 180)
    }

    @Test
    func `Degenerate inputs return nil`() {
        let pointSize = CGSize(width: 100, height: 100)
        let backdrop = Self.solidImage(pointSize: pointSize, gray: 0.5)

        #expect(CanvasBackdropRenderer.blurredCrop(
            from: backdrop,
            backdropPointSize: pointSize,
            rect: CGRect(x: 10, y: 10, width: 0, height: 40),
            blurRadius: 10,
        ) == nil)

        #expect(CanvasBackdropRenderer.blurredCrop(
            from: backdrop,
            backdropPointSize: .zero,
            rect: CGRect(x: 10, y: 10, width: 40, height: 40),
            blurRadius: 10,
        ) == nil)
    }

    // MARK: - Blur

    @Test
    func `Blur output differs from the unblurred source crop`() throws {
        let pointSize = CGSize(width: 200, height: 150)
        let backdrop = Self.checkerboardImage(pointSize: pointSize)
        let rect = CGRect(x: 50, y: 40, width: 80, height: 60)

        let blurred = try #require(CanvasBackdropRenderer.blurredCrop(
            from: backdrop,
            backdropPointSize: pointSize,
            rect: rect,
            blurRadius: 8,
        ))

        // The same crop taken directly from the source. CGImage cropping uses a
        // top-left-origin raster space, so only the y axis conversion differs from
        // the renderer's bottom-left CoreImage space.
        let scale: CGFloat = 2
        let sourceCrop = try #require(backdrop.cropping(to: CGRect(
            x: rect.minX * scale,
            y: rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale,
        )))

        #expect(blurred.width == sourceCrop.width)
        #expect(blurred.height == sourceCrop.height)
        #expect(Self.rgbaBytes(of: blurred) != Self.rgbaBytes(of: sourceCrop))
    }

    @Test
    func `Edge-clamped blur does not darken borders of a solid backdrop`() throws {
        let pointSize = CGSize(width: 100, height: 80)
        let gray: CGFloat = 0.5
        let backdrop = Self.solidImage(pointSize: pointSize, gray: gray)

        // Panel rect flush with the backdrop's corner, so the blur kernel reaches
        // beyond the image on two sides. Without clamping, those samples would be
        // transparent black and the border pixels would darken and lose alpha.
        let blurred = try #require(CanvasBackdropRenderer.blurredCrop(
            from: backdrop,
            backdropPointSize: pointSize,
            rect: CGRect(x: 0, y: 0, width: 50, height: 40),
            blurRadius: 20,
        ))

        let bytes = Self.rgbaBytes(of: blurred)
        let expected = UInt8((gray * 255).rounded())
        let tolerance = 4

        for pixelStart in stride(from: 0, to: bytes.count, by: 4) {
            for channel in 0 ..< 3 {
                let value = Int(bytes[pixelStart + channel])
                #expect(
                    abs(value - Int(expected)) <= tolerance,
                    "channel \(channel) at byte \(pixelStart) is \(value), expected ~\(expected)",
                )
            }
            #expect(bytes[pixelStart + 3] >= UInt8(255 - tolerance))
        }
    }

    // MARK: - Backdrop Composite Parity

    @Test
    func `renderPanelBackdrop matches the built background beneath panels`() throws {
        var config = DMGConfiguration()
        config.window = WindowConfiguration(width: 200, height: 150)
        config.background.type = .gradient
        config.background.gradient = GradientConfiguration()
        config.textLayers = [
            TextLayerConfiguration(
                text: "Backdrop",
                position: CGPoint(x: 100, y: 60),
                fontSize: 20,
                color: RGBColor(red: 1, green: 1, blue: 1),
            ),
        ]

        let backdrop = try #require(CompositeRenderer.renderPanelBackdrop(
            configuration: config,
            layerImages: [:],
            scale: 2,
        ))
        #expect(backdrop.width == 400)
        #expect(backdrop.height == 300)

        // With no items, the full composite contains nothing but the beneath-panels
        // content, so the 2x representation must be pixel-identical to the backdrop.
        let full = try #require(CompositeRenderer.renderBackground(
            configuration: config,
            assetsDirectory: FileManager.default.temporaryDirectory,
        ))
        let rep2 = try #require(
            full.representations
                .compactMap { $0 as? NSBitmapImageRep }
                .first { $0.pixelsWide == 400 },
        )
        let builtImage = try #require(rep2.cgImage)

        #expect(Self.rgbaBytes(of: backdrop) == Self.rgbaBytes(of: builtImage))
    }
}
