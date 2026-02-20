import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

nonisolated enum CompositeRenderer {
    private static let ciContext = CIContext()

    // MARK: - Composite Background

    static func renderBackground(
        configuration: DMGConfiguration,
        assetsDirectory: URL
    ) -> NSImage? {
        let width = configuration.window.width
        let height = configuration.window.height

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        defer { image.unlockFocus() }

        guard let context = NSGraphicsContext.current?.cgContext else { return nil }

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)

        renderBaseBackground(context: context, configuration: configuration, rect: fullRect)

        if configuration.background.type == .image {
            renderImageLayers(
                context: context,
                layers: configuration.background.layers,
                assetsDirectory: assetsDirectory,
                canvasWidth: width,
                canvasHeight: height
            )
        }

        renderTextLayers(configuration.textLayers, in: context, canvasHeight: height)
        renderSFSymbolLayers(configuration.sfSymbolLayers, in: context, canvasHeight: height)
        renderItemBackgrounds(
            items: configuration.items,
            iconSize: configuration.iconSize,
            in: context,
            canvasHeight: height
        )

        return image
    }

    // MARK: - Base Background

    private static func renderBaseBackground(
        context: CGContext,
        configuration: DMGConfiguration,
        rect: CGRect
    ) {
        switch configuration.background.type {
        case .none:
            context.clear(rect)
        case .color, .image:
            let bgColor = configuration.background.color
            context.setFillColor(CGColor(
                srgbRed: bgColor.red, green: bgColor.green, blue: bgColor.blue, alpha: 1
            ))
            context.fill(rect)
        case .gradient:
            if let grad = configuration.background.gradient {
                renderGradient(context: context, gradient: grad, rect: rect)
            } else {
                context.clear(rect)
            }
        }
    }

    // MARK: - Image Layers

    private static func renderImageLayers(
        context _: CGContext,
        layers: [BackgroundLayer],
        assetsDirectory: URL,
        canvasWidth: CGFloat,
        canvasHeight: CGFloat
    ) {
        for layer in layers {
            let imageURL = assetsDirectory.appending(path: layer.imageName)
            guard let layerImage = NSImage(contentsOf: imageURL) else { continue }

            let imageSize = layerImage.size
            let displayWidth = canvasWidth * layer.scale
            let displayHeight: CGFloat = if imageSize.width > 0 {
                displayWidth * (imageSize.height / imageSize.width)
            } else {
                displayWidth
            }

            let processedImage = applyLayerEffects(
                to: layerImage,
                layer: layer,
                displaySize: CGSize(width: displayWidth, height: displayHeight)
            )

            let originX = layer.position.x - displayWidth / 2
            let originY = canvasHeight - layer.position.y - displayHeight / 2

            processedImage.draw(
                in: NSRect(x: originX, y: originY, width: displayWidth, height: displayHeight),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
        }
    }

    // MARK: - Text Layers

    private static func renderTextLayers(
        _ textLayers: [TextLayerConfiguration],
        in _: CGContext,
        canvasHeight: CGFloat
    ) {
        for textLayer in textLayers {
            var fontTraits: NSFontDescriptor.SymbolicTraits = []
            if textLayer.isBold { fontTraits.insert(.bold) }
            if textLayer.isItalic { fontTraits.insert(.italic) }

            let baseFont = NSFont(name: textLayer.fontFamily, size: textLayer.fontSize)
                ?? NSFont.systemFont(ofSize: textLayer.fontSize)

            let font: NSFont
            if !fontTraits.isEmpty {
                let descriptor = baseFont.fontDescriptor.withSymbolicTraits(fontTraits)
                font = NSFont(descriptor: descriptor, size: textLayer.fontSize) ?? baseFont
            } else {
                font = baseFont
            }

            let color = NSColor(
                srgbRed: textLayer.color.red,
                green: textLayer.color.green,
                blue: textLayer.color.blue,
                alpha: 1
            )

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]

            let string = NSAttributedString(string: textLayer.text, attributes: attributes)
            let size = string.size()

            let drawX = textLayer.position.x - size.width / 2
            let drawY = canvasHeight - textLayer.position.y - size.height / 2

            string.draw(at: NSPoint(x: drawX, y: drawY))
        }
    }

    // MARK: - SF Symbol Layers

    private static func renderSFSymbolLayers(
        _ symbolLayers: [SFSymbolLayerConfiguration],
        in _: CGContext,
        canvasHeight: CGFloat
    ) {
        for symbolLayer in symbolLayers {
            let config = NSImage.SymbolConfiguration(
                pointSize: symbolLayer.pointSize,
                weight: symbolLayer.weight.nsFontWeight
            )
            guard let symbolImage = NSImage(
                systemSymbolName: symbolLayer.symbolName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(config) else { continue }

            let tintedImage = NSImage(size: symbolImage.size, flipped: false) { rect in
                symbolImage.draw(in: rect)
                NSColor(
                    srgbRed: symbolLayer.color.red,
                    green: symbolLayer.color.green,
                    blue: symbolLayer.color.blue,
                    alpha: 1
                ).set()
                rect.fill(using: .sourceAtop)
                return true
            }

            let symbolSize = tintedImage.size
            let originX = symbolLayer.position.x - symbolSize.width / 2
            let originY = canvasHeight - symbolLayer.position.y - symbolSize.height / 2

            tintedImage.draw(
                in: NSRect(x: originX, y: originY, width: symbolSize.width, height: symbolSize.height),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
        }
    }

    // MARK: - Item Backgrounds

    /// Dimensions match CanvasView: icon cell (iconSize + 20) + text gap (4) + text (~20)
    private static func renderItemBackgrounds(
        items: [CanvasItem],
        iconSize: CGFloat,
        in context: CGContext,
        canvasHeight: CGFloat
    ) {
        let iconCellPadding: CGFloat = 10
        let textGap: CGFloat = 4
        let estimatedTextHeight: CGFloat = 20

        for item in items {
            guard let bg = item.background,
                  bg.enabled || bg.shadow?.enabled == true || bg.bevel?.enabled == true
            else { continue }

            let contentHeight = iconSize + iconCellPadding * 2 + textGap + estimatedTextHeight
            let bgSide = contentHeight + bg.padding * 2
            let originX = item.position.x - bgSide / 2
            let originY = canvasHeight - item.position.y - bgSide / 2
            let bgRect = CGRect(x: originX, y: originY, width: bgSide, height: bgSide)

            renderItemShadow(bg: bg, rect: bgRect, in: context)
            renderItemPanel(bg: bg, rect: bgRect, in: context)

            if let bevel = bg.bevel, bevel.enabled {
                renderBevel(context: context, rect: bgRect, cornerRadius: bg.cornerRadius, bevel: bevel)
            }
        }
    }

    private static func renderItemShadow(
        bg: ItemBackground,
        rect: CGRect,
        in context: CGContext
    ) {
        guard let shadow = bg.shadow, shadow.enabled else { return }

        let shadowColor = CGColor(
            srgbRed: shadow.color.red,
            green: shadow.color.green,
            blue: shadow.color.blue,
            alpha: shadow.opacity
        )
        let shadowPath = CGPath(
            roundedRect: rect,
            cornerWidth: bg.cornerRadius,
            cornerHeight: bg.cornerRadius,
            transform: nil
        )

        // Use transparency layer so we can erase the casting shape,
        // leaving only the shadow visible outside the panel area.
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        context.setShadow(
            offset: CGSize(width: shadow.offsetX, height: -shadow.offsetY),
            blur: shadow.radius,
            color: shadowColor
        )
        context.addPath(shadowPath)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()

        // Erase the casting shape, keeping only the shadow
        context.setBlendMode(.clear)
        context.addPath(shadowPath)
        context.fillPath()

        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func renderItemPanel(
        bg: ItemBackground,
        rect: CGRect,
        in context: CGContext
    ) {
        guard bg.enabled else { return }

        let cornerRadius = bg.cornerRadius

        if bg.blurRadius > 0 {
            if bg.blurFeather > 0 {
                renderFeatheredBlurRegion(
                    context: context, rect: rect, cornerRadius: cornerRadius,
                    blurRadius: bg.blurRadius, feather: bg.blurFeather
                )
            } else {
                renderBlurredRegion(
                    context: context, rect: rect, cornerRadius: cornerRadius,
                    blurRadius: bg.blurRadius
                )
            }
        }

        let bgColor = CGColor(
            srgbRed: bg.color.red, green: bg.color.green,
            blue: bg.color.blue, alpha: bg.opacity
        )

        if bg.blurFeather > 0 {
            guard let maskImage = generateContourMask(
                size: rect.size, cornerRadius: cornerRadius, feather: bg.blurFeather
            ) else { return }

            context.saveGState()
            context.clip(to: rect, mask: maskImage)
            context.setBlendMode(bg.blendMode.cgBlendMode)
            context.setFillColor(bgColor)
            context.fill(rect)
            context.restoreGState()
        } else {
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                transform: nil
            )
            context.saveGState()
            context.addPath(path)
            context.clip()
            context.setBlendMode(bg.blendMode.cgBlendMode)
            context.setFillColor(bgColor)
            context.fill(rect)
            context.restoreGState()
        }
    }

    // MARK: - Layer Effects Pipeline

    /// Applies all configured effects to a background layer image.
    /// Resizes to `displaySize` first so both the preview and build produce identical output.
    static func applyLayerEffects(
        to image: NSImage,
        layer: BackgroundLayer,
        displaySize: CGSize
    ) -> NSImage {
        // Resize to target display size before applying effects
        let source: NSImage = if abs(image.size.width - displaySize.width) > 1
            || abs(image.size.height - displaySize.height) > 1 {
            resizeImage(image, to: displaySize)
        } else {
            image
        }

        guard let tiffData = source.tiffRepresentation,
              var ciImage = CIImage(data: tiffData) else { return source }
        let extent = ciImage.extent

        // 1. Blur (variable or gaussian, not both)
        if let vb = layer.variableBlur {
            ciImage = applyVariableBlur(to: ciImage, config: vb)
        } else if layer.blurRadius > 0 {
            let f = CIFilter.gaussianBlur()
            f.inputImage = ciImage
            f.radius = Float(layer.blurRadius)
            if let out = f.outputImage {
                ciImage = out.cropped(to: extent)
            }
        }

        // 2. Color adjustments
        if let ca = layer.colorAdjustments {
            ciImage = applyColorAdjustments(to: ciImage, adjustments: ca)
        }

        // 3. Vignette
        if let v = layer.vignette {
            let f = CIFilter.vignette()
            f.inputImage = ciImage
            f.intensity = Float(v.intensity)
            f.radius = Float(v.radius)
            if let out = f.outputImage {
                ciImage = out.cropped(to: extent)
            }
        }

        // 4. Bloom
        if let b = layer.bloom {
            let f = CIFilter.bloom()
            f.inputImage = ciImage
            f.intensity = Float(b.intensity)
            f.radius = Float(b.radius)
            if let out = f.outputImage {
                ciImage = out.cropped(to: extent)
            }
        }

        let ctx = ciContext
        guard let cg = ctx.createCGImage(ciImage, from: extent) else { return source }
        return NSImage(cgImage: cg, size: displaySize)
    }

    private static func applyColorAdjustments(to image: CIImage, adjustments ca: ColorAdjustments) -> CIImage {
        let extent = image.extent
        var result = image

        if ca.brightness != 0 || ca.contrast != 1 || ca.saturation != 1 {
            let f = CIFilter.colorControls()
            f.inputImage = result
            f.brightness = Float(ca.brightness)
            f.contrast = Float(ca.contrast)
            f.saturation = Float(ca.saturation)
            if let out = f.outputImage { result = out.cropped(to: extent) }
        }
        if ca.hueRotation != 0 {
            let f = CIFilter.hueAdjust()
            f.inputImage = result
            f.angle = Float(ca.hueRotation * .pi / 180)
            if let out = f.outputImage { result = out.cropped(to: extent) }
        }
        if ca.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = result
            f.ev = Float(ca.exposure)
            if let out = f.outputImage { result = out.cropped(to: extent) }
        }

        return result
    }

    static func resizeImage(_ image: NSImage, to size: CGSize) -> NSImage {
        let newImage = NSImage(size: size)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        newImage.unlockFocus()
        return newImage
    }

    static func applyVariableBlur(to image: CIImage, config: VariableBlurConfiguration) -> CIImage {
        let extent = image.extent

        // Generate gradient mask based on maskType
        let mask: CIImage
        switch config.maskType {
        case .linear:
            let radians = config.angle * .pi / 180
            let cx = extent.midX
            let cy = extent.midY
            let halfDiag = sqrt(extent.width * extent.width + extent.height * extent.height) / 2
            let point0 = CGPoint(
                x: cx + cos(radians + .pi) * halfDiag,
                y: cy + sin(radians + .pi) * halfDiag
            )
            let point1 = CGPoint(
                x: cx + cos(radians) * halfDiag,
                y: cy + sin(radians) * halfDiag
            )
            let grad = CIFilter.smoothLinearGradient()
            grad.point0 = point0
            grad.point1 = point1
            grad.color0 = CIColor.black // sharp
            grad.color1 = CIColor.white // blurred
            mask = grad.outputImage!.cropped(to: extent)

        case .radial:
            let grad = CIFilter.radialGradient()
            grad.center = CGPoint(
                x: extent.width * config.centerX,
                y: extent.height * config.centerY
            )
            grad.radius0 = Float(extent.width * config.startPoint)
            grad.radius1 = Float(extent.width * config.endPoint)
            grad.color0 = CIColor.black // sharp center
            grad.color1 = CIColor.white // blurred edges
            mask = grad.outputImage!.cropped(to: extent)
        }

        let filter = CIFilter.maskedVariableBlur()
        filter.inputImage = image
        filter.mask = mask
        filter.radius = Float(config.radius)
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: - Gradient Rendering

    static func renderGradient(
        context: CGContext,
        gradient: GradientConfiguration,
        rect: CGRect
    ) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let sortedStops = gradient.stops.sorted { $0.location < $1.location }
        var cgColors: [CGColor] = []
        var locations: [CGFloat] = []
        for stop in sortedStops {
            cgColors.append(CGColor(
                srgbRed: stop.color.red,
                green: stop.color.green,
                blue: stop.color.blue,
                alpha: 1
            ))
            locations.append(stop.location)
        }
        guard let cgGradient = CGGradient(
            colorsSpace: colorSpace,
            colors: cgColors as CFArray,
            locations: &locations
        ) else { return }

        context.saveGState()
        context.clip(to: rect)

        switch gradient.type {
        case .linear:
            let radians = gradient.angle * .pi / 180
            let cx = rect.midX
            let cy = rect.midY
            let halfDiag = max(rect.width, rect.height) / 2
            let startPoint = CGPoint(
                x: cx + cos(radians + .pi) * halfDiag,
                y: cy - sin(radians + .pi) * halfDiag // y-up in CG
            )
            let endPoint = CGPoint(
                x: cx + cos(radians) * halfDiag,
                y: cy - sin(radians) * halfDiag
            )
            context.drawLinearGradient(
                cgGradient,
                start: startPoint,
                end: endPoint,
                options: [.drawsAfterEndLocation, .drawsBeforeStartLocation]
            )

        case .radial:
            let center = CGPoint(
                x: rect.width * gradient.centerX,
                y: rect.height * (1 - gradient.centerY) // flip y for CG
            )
            let r0 = gradient.startRadius * rect.width
            let r1 = gradient.endRadius * rect.width
            context.drawRadialGradient(
                cgGradient,
                startCenter: center,
                startRadius: r0,
                endCenter: center,
                endRadius: r1,
                options: [.drawsAfterEndLocation]
            )
        }

        context.restoreGState()
    }

    // MARK: - Bevel Rendering

    static func renderBevelImage(
        size: CGSize,
        cornerRadius: CGFloat,
        bevel: BevelConfiguration
    ) -> NSImage? {
        guard size.width > 0, size.height > 0 else { return nil }

        // 1. Create white rounded rect mask on black background
        let maskImage = NSImage(size: size)
        maskImage.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.white.setFill()
        NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: size),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        ).fill()
        maskImage.unlockFocus()

        guard let maskTiff = maskImage.tiffRepresentation,
              let ciMask = CIImage(data: maskTiff) else { return nil }

        // 2. CIHeightFieldFromMask
        let heightField = CIFilter.heightFieldFromMask()
        heightField.inputImage = ciMask
        heightField.radius = Float(bevel.depth)
        guard let heightOutput = heightField.outputImage else { return nil }

        // 3. Generate shading sphere
        let shadingSphere = generateShadingSphere(lightAngle: bevel.lightAngle, size: 128)

        // 4. CIShadedMaterial
        let shaded = CIFilter.shadedMaterial()
        shaded.inputImage = heightOutput
        shaded.shadingImage = shadingSphere
        shaded.scale = Float(bevel.intensity * 20)
        guard let shadedOutput = shaded.outputImage?.cropped(to: ciMask.extent) else { return nil }

        // 5. Convert to NSImage
        let ciContext = Self.ciContext
        guard let cgBevel = ciContext.createCGImage(shadedOutput, from: ciMask.extent) else { return nil }
        return NSImage(cgImage: cgBevel, size: size)
    }

    static func renderBevel(
        context: CGContext,
        rect: CGRect,
        cornerRadius: CGFloat,
        bevel: BevelConfiguration
    ) {
        guard let bevelImage = renderBevelImage(
            size: rect.size,
            cornerRadius: cornerRadius,
            bevel: bevel
        ), let cgBevel = bevelImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }

        context.saveGState()
        context.setBlendMode(.softLight)
        context.draw(cgBevel, in: rect)
        context.restoreGState()
    }

    static func generateShadingSphere(lightAngle: CGFloat, size: Int = 128) -> CIImage {
        let radians = lightAngle * .pi / 180
        let lightX = cos(radians)
        let lightY = sin(radians)
        let lightZ: CGFloat = 0.5
        let lightLen = sqrt(lightX * lightX + lightY * lightY + lightZ * lightZ)
        let lx = lightX / lightLen
        let ly = lightY / lightLen
        let lz = lightZ / lightLen

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let center = CGFloat(size) / 2
        let radius = center - 1

        for y in 0 ..< size {
            for x in 0 ..< size {
                let dx = (CGFloat(x) - center) / radius
                let dy = (CGFloat(y) - center) / radius
                let dist2 = dx * dx + dy * dy

                let intensity: CGFloat
                if dist2 <= 1.0 {
                    let nz = sqrt(1.0 - dist2)
                    let dot = dx * lx + dy * ly + nz * lz
                    let diffuse = max(dot, 0)
                    let specular = pow(max(dot, 0), 4)
                    intensity = min(0.3 + 0.5 * diffuse + 0.2 * specular, 1.0)
                } else {
                    intensity = 0.5
                }

                let idx = (y * size + x) * 4
                let byte = UInt8(intensity * 255)
                pixels[idx] = byte // R
                pixels[idx + 1] = byte // G
                pixels[idx + 2] = byte // B
                pixels[idx + 3] = 255 // A
            }
        }

        let data = Data(pixels)
        return CIImage(
            bitmapData: data,
            bytesPerRow: size * 4,
            size: CGSize(width: size, height: size),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
    }

    // MARK: - Blur Helpers

    static func renderBlurredRegion(
        context: CGContext,
        rect: CGRect,
        cornerRadius: CGFloat,
        blurRadius: CGFloat
    ) {
        guard let currentBitmap = context.makeImage() else { return }
        let ciImage = CIImage(cgImage: currentBitmap)

        // Expand capture area to include blur kernel padding
        let padding = blurRadius * 3
        let expandedRect = rect.insetBy(dx: -padding, dy: -padding)
        let cropped = ciImage.cropped(to: expandedRect)

        let filter = CIFilter.gaussianBlur()
        filter.inputImage = cropped
        filter.radius = Float(blurRadius)

        guard let blurred = filter.outputImage?.cropped(to: rect) else { return }

        let ciContext = Self.ciContext
        guard let cgBlurred = ciContext.createCGImage(blurred, from: rect) else { return }

        let path = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(cgBlurred, in: rect)
        context.restoreGState()
    }

    static func renderFeatheredBlurRegion(
        context: CGContext,
        rect: CGRect,
        cornerRadius: CGFloat,
        blurRadius: CGFloat,
        feather: CGFloat
    ) {
        guard let currentBitmap = context.makeImage() else { return }
        let ciImage = CIImage(cgImage: currentBitmap)

        let padding = blurRadius * 3
        let expandedRect = rect.insetBy(dx: -padding, dy: -padding)
        let cropped = ciImage.cropped(to: expandedRect)

        // Generate contour-following mask for variable blur
        guard let maskImage = generateContourMask(
            size: rect.size,
            cornerRadius: cornerRadius,
            feather: feather
        ) else { return }

        let ciMask = CIImage(cgImage: maskImage)
            .transformed(by: CGAffineTransform(translationX: rect.origin.x, y: rect.origin.y))

        let filter = CIFilter.maskedVariableBlur()
        filter.inputImage = cropped
        filter.mask = ciMask.cropped(to: expandedRect)
        filter.radius = Float(blurRadius)

        guard let blurred = filter.outputImage?.cropped(to: rect) else { return }

        let ciContext = Self.ciContext
        guard let cgBlurred = ciContext.createCGImage(blurred, from: rect) else { return }

        // Draw with the same contour mask for proper edge fade
        context.saveGState()
        context.clip(to: rect, mask: maskImage)
        context.draw(cgBlurred, in: rect)
        context.restoreGState()
    }

    /// Generates a contour-following mask: white at center, black at edges,
    /// following the rounded rectangle shape.
    static func generateContourMask(
        size: CGSize,
        cornerRadius: CGFloat,
        feather: CGFloat
    ) -> CGImage? {
        let featherPx = min(size.width, size.height) * feather * 0.5
        let insetRect = CGRect(origin: .zero, size: size).insetBy(dx: featherPx, dy: featherPx)
        let insetCR = max(cornerRadius - featherPx, 0)

        // Draw white rounded rect on black background, then blur to create feathered edge
        let maskNS = NSImage(size: size)
        maskNS.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: insetRect, xRadius: insetCR, yRadius: insetCR).fill()
        maskNS.unlockFocus()

        guard let tiff = maskNS.tiffRepresentation,
              let ciMask = CIImage(data: tiff) else { return nil }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = ciMask
        blur.radius = Float(featherPx)
        guard let blurred = blur.outputImage?.cropped(to: CGRect(origin: .zero, size: size)) else { return nil }

        let ctx = ciContext
        return ctx.createCGImage(blurred, from: CGRect(origin: .zero, size: size))
    }
}
