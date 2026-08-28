import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Mesh Gradient

nonisolated extension CompositeRenderer {
    /// Draws a mesh gradient across `rect`.
    static func renderMesh(
        context: CGContext,
        mesh: MeshGradientConfiguration,
        rect: CGRect,
        scale: CGFloat,
    ) {
        let pixelsWide = Int((rect.width * scale).rounded())
        let pixelsHigh = Int((rect.height * scale).rounded())
        guard let image = renderMeshImage(mesh: mesh, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)
        else { return }

        context.saveGState()
        context.draw(image, in: rect)
        context.restoreGState()
    }

    /// The mesh rasterized into its own bitmap, one evaluation per pixel.
    ///
    /// The interpolation is separable — a patch weight in u depends only on the column
    /// and one in v only on the row — so the column weights and cell indices are computed
    /// once for the whole image and each row then costs three lerps per channel. Written
    /// the obvious way instead, a window-sized mesh takes seconds.
    static func renderMeshImage(
        mesh: MeshGradientConfiguration,
        pixelsWide: Int,
        pixelsHigh: Int,
    ) -> CGImage? {
        guard pixelsWide > 0, pixelsHigh > 0, mesh.isDrawable else { return nil }

        let columns = mesh.columns
        let smoothed = mesh.smoothsColors
        let reds = mesh.points.map { Double($0.color.red) }
        let greens = mesh.points.map { Double($0.color.green) }
        let blues = mesh.points.map { Double($0.color.blue) }

        var columnCell = [Int](repeating: 0, count: pixelsWide)
        var columnWeight = [Double](repeating: 0, count: pixelsWide)
        for x in 0 ..< pixelsWide {
            let scaled = (Double(x) + 0.5) / Double(pixelsWide) * Double(columns - 1)
            let cell = min(Int(scaled), columns - 2)
            columnCell[x] = cell
            columnWeight[x] = Double(MeshGradientConfiguration.weight(
                CGFloat(scaled - Double(cell)), smoothed: smoothed,
            ))
        }

        var pixels = [UInt8](repeating: 255, count: pixelsWide * pixelsHigh * 4)
        pixels.withUnsafeMutableBufferPointer { buffer in
            for y in 0 ..< pixelsHigh {
                let scaledV = (Double(y) + 0.5) / Double(pixelsHigh) * Double(mesh.rows - 1)
                let cellRow = min(Int(scaledV), mesh.rows - 2)
                let weightV = Double(MeshGradientConfiguration.weight(
                    CGFloat(scaledV - Double(cellRow)), smoothed: smoothed,
                ))
                let topRow = cellRow * columns
                let bottomRow = (cellRow + 1) * columns
                let rowStart = y * pixelsWide * 4

                for x in 0 ..< pixelsWide {
                    let cell = columnCell[x]
                    let weightU = columnWeight[x]
                    let topLeft = topRow + cell
                    let bottomLeft = bottomRow + cell

                    func channel(_ values: [Double]) -> UInt8 {
                        let top = values[topLeft] + (values[topLeft + 1] - values[topLeft]) * weightU
                        let bottom = values[bottomLeft] + (values[bottomLeft + 1] - values[bottomLeft]) * weightU
                        let value = top + (bottom - top) * weightV
                        return UInt8(min(max(value, 0), 1) * 255)
                    }

                    let index = rowStart + x * 4
                    buffer[index] = channel(reds)
                    buffer[index + 1] = channel(greens)
                    buffer[index + 2] = channel(blues)
                }
            }
        }

        return makeImage(rgba: pixels, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)
    }
}

// MARK: - Grain

nonisolated extension CompositeRenderer {
    /// The grain laid over a finished background, as straight black-and-white speckle
    /// with a low alpha.
    ///
    /// Deliberately an ordinary source-over overlay rather than a blend mode or a pixel
    /// operation: the canvas composites the same image the same way, so grain cannot be
    /// one thing in the editor and another in the disk image.
    static func renderGrainImage(
        grain: GrainConfiguration,
        pointSize: CGSize,
        scale: CGFloat,
    ) -> CGImage? {
        guard grain.enabled, grain.amount > 0 else { return nil }

        // Grain is generated at its cell size and drawn back up, so `size` is a real
        // texture control rather than a resampling artifact.
        let cell = max(grain.size, 0.25)
        let pixelsWide = Int((pointSize.width * scale / cell).rounded())
        let pixelsHigh = Int((pointSize.height * scale / cell).rounded())
        guard pixelsWide > 0, pixelsHigh > 0 else { return nil }

        let peak = min(max(grain.amount, 0), 1) * 255
        var random = SplitMix64(seed: 0x5249_4C4D_415A_4146)
        var pixels = [UInt8](repeating: 0, count: pixelsWide * pixelsHigh * 4)

        for index in stride(from: 0, to: pixels.count, by: 4) {
            func speckle() -> (value: UInt8, alpha: UInt8) {
                // Signed noise: negative darkens, positive lightens, and |value| sets how
                // strongly. Premultiplied, so the color channel is 0 or the alpha itself.
                let signed = random.nextUnitInterval() * 2 - 1
                let alpha = UInt8((abs(signed) * peak).rounded())
                return (signed > 0 ? alpha : 0, alpha)
            }

            if grain.isColored {
                let red = speckle(), green = speckle(), blue = speckle()
                let alpha = max(red.alpha, max(green.alpha, blue.alpha))
                pixels[index] = min(red.value, alpha)
                pixels[index + 1] = min(green.value, alpha)
                pixels[index + 2] = min(blue.value, alpha)
                pixels[index + 3] = alpha
            } else {
                let (value, alpha) = speckle()
                pixels[index] = value
                pixels[index + 1] = value
                pixels[index + 2] = value
                pixels[index + 3] = alpha
            }
        }

        return makeImage(rgba: pixels, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh)
    }

    /// Lays grain over everything already drawn into `context`.
    static func renderGrain(
        context: CGContext,
        grain: GrainConfiguration,
        rect: CGRect,
        scale: CGFloat,
    ) {
        guard let image = renderGrainImage(grain: grain, pointSize: rect.size, scale: scale) else { return }
        context.saveGState()
        context.interpolationQuality = grain.size > 1 ? .none : .default
        context.draw(image, in: rect)
        context.restoreGState()
    }
}

// MARK: - Gradient Map

nonisolated extension CompositeRenderer {
    /// Re-colors `image` by brightness: the darkest pixels take the first stop, the
    /// brightest the last, and `amount` carries the result back toward the original.
    static func applyGradientMap(to image: CIImage, config: GradientMapConfiguration) -> CIImage {
        guard config.enabled, config.amount > 0,
              let ramp = gradientRampImage(stops: config.stops)
        else { return image }

        let extent = image.extent
        let map = CIFilter.colorMap()
        map.inputImage = image
        map.gradientImage = CIImage(cgImage: ramp)
        guard let mapped = map.outputImage?.cropped(to: extent) else { return image }

        let blend = min(max(config.amount, 0), 1)
        guard blend < 1 else { return mapped }

        // Fade the mapped copy in over the original by scaling its alpha, which keeps the
        // whole pass inside CoreImage's deterministic software path.
        let fade = CIFilter.colorMatrix()
        fade.inputImage = mapped
        fade.aVector = CIVector(x: 0, y: 0, z: 0, w: blend)
        guard let faded = fade.outputImage else { return mapped }

        return faded.composited(over: image).cropped(to: extent)
    }

    /// A 256×1 ramp of `stops`, the lookup `CIColorMap` reads brightness through.
    static func gradientRampImage(stops: [GradientStop]) -> CGImage? {
        let sorted = stops.sorted { $0.location < $1.location }
        guard let first = sorted.first, let last = sorted.last,
              let context = makeBitmapContext(pixelsWide: 256, pixelsHigh: 1)
        else { return nil }

        let colors = sorted.map {
            CGColor(srgbRed: $0.color.red, green: $0.color.green, blue: $0.color.blue, alpha: 1)
        }
        let locations = sorted.map { min(max($0.location, 0), 1) }

        guard sorted.count > 1,
              let gradient = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: locations)
        else {
            context.setFillColor(CGColor(
                srgbRed: first.color.red, green: first.color.green, blue: first.color.blue, alpha: 1,
            ))
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 1))
            return context.makeImage()
        }

        // Ends are clamped so brightness below the first stop or above the last still
        // lands on a color rather than on transparency.
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 256 * locations[0], y: 0),
            end: CGPoint(x: 256 * locations[locations.count - 1], y: 0),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation],
        )
        _ = last
        return context.makeImage()
    }
}

// MARK: - Glass Edge

nonisolated extension CompositeRenderer {
    /// Draws a panel's glass edge: a hairline border brightest where the light falls, and
    /// a shadow cast inward from the opposite edge.
    ///
    /// This is the treatment that reads as glass rather than as embossed plastic — a
    /// bevel lights a raised surface, where a pane of glass catches light on one rim and
    /// pools shadow under the other.
    static func renderGlassEdge(
        context: CGContext,
        glass: GlassConfiguration,
        rect: CGRect,
        cornerRadius: CGFloat,
        scale: CGFloat,
    ) {
        let shape = CGPath(
            roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil,
        )
        let radians = glass.lightAngle * .pi / 180
        let light = CGPoint(x: cos(radians), y: sin(radians))

        renderGlassInnerShadow(
            context: context, glass: glass, rect: rect, shape: shape, light: light, scale: scale,
        )
        renderGlassBorder(
            context: context, glass: glass, rect: rect, cornerRadius: cornerRadius, light: light,
        )
    }

    /// A shadow pooled inside the panel's unlit edge: the shape's complement is filled
    /// with a shadow that spills inward, clipped to the shape itself.
    private static func renderGlassInnerShadow(
        context: CGContext,
        glass: GlassConfiguration,
        rect: CGRect,
        shape: CGPath,
        light: CGPoint,
        scale: CGFloat,
    ) {
        guard glass.innerShadowOpacity > 0, glass.innerShadowRadius > 0 else { return }

        let offset = glass.innerShadowRadius * 0.4
        let complement = CGMutablePath()
        complement.addRect(rect.insetBy(dx: -glass.innerShadowRadius * 4, dy: -glass.innerShadowRadius * 4))
        complement.addPath(shape)

        context.saveGState()
        context.addPath(shape)
        context.clip()
        context.setShadow(
            offset: CGSize(width: -light.x * offset * scale, height: -light.y * offset * scale),
            blur: glass.innerShadowRadius * scale,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: glass.innerShadowOpacity),
        )
        context.addPath(complement)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    /// A hairline rim, brightest on the lit side and fading around to a quarter of that.
    private static func renderGlassBorder(
        context: CGContext,
        glass: GlassConfiguration,
        rect: CGRect,
        cornerRadius: CGFloat,
        light: CGPoint,
    ) {
        guard glass.borderWidth > 0, glass.borderOpacity > 0 else { return }

        let inset = glass.borderWidth / 2
        let stroke = CGPath(
            roundedRect: rect.insetBy(dx: inset, dy: inset),
            cornerWidth: max(cornerRadius - inset, 0),
            cornerHeight: max(cornerRadius - inset, 0),
            transform: nil,
        )
        let opacity = min(max(glass.borderOpacity, 0), 1)
        guard let gradient = CGGradient(
            colorsSpace: sRGB,
            colors: [
                CGColor(srgbRed: 1, green: 1, blue: 1, alpha: opacity),
                CGColor(srgbRed: 1, green: 1, blue: 1, alpha: opacity * 0.25),
            ] as CFArray,
            locations: [0, 1],
        ) else { return }

        context.saveGState()
        context.addPath(stroke)
        context.setLineWidth(glass.borderWidth)
        context.replacePathWithStrokedPath()
        context.clip()

        let half = CGPoint(x: rect.midX, y: rect.midY)
        let reach = max(rect.width, rect.height) / 2
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: half.x + light.x * reach, y: half.y + light.y * reach),
            end: CGPoint(x: half.x - light.x * reach, y: half.y - light.y * reach),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation],
        )
        context.restoreGState()
    }
}

// MARK: - Shared Helpers

nonisolated extension CompositeRenderer {
    /// Wraps straight RGBA8 bytes as a `CGImage` in the renderer's fixed sRGB space.
    static func makeImage(rgba: [UInt8], pixelsWide: Int, pixelsHigh: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: pixelsWide,
            height: pixelsHigh,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: pixelsWide * 4,
            space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent,
        )
    }

    static func lerp(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat {
        from + (to - from) * t
    }

    static func smoothstep(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    static func byte(_ value: CGFloat) -> UInt8 {
        UInt8(min(max(value, 0), 1) * 255)
    }
}

/// A small deterministic generator, so grain is the same speckle on every machine and on
/// every rebuild. `SystemRandomNumberGenerator` would make the baked background differ
/// from one build to the next, which the determinism guarantee does not allow.
nonisolated struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in 0..<1, taken from the high bits where the generator is strongest.
    mutating func nextUnitInterval() -> CGFloat {
        CGFloat(next() >> 11) / CGFloat(1 << 53)
    }
}
