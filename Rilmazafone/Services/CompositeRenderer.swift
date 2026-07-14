import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

nonisolated enum CompositeRenderer {
    /// Fixed sRGB color space used for every offscreen bitmap and CoreImage pass, so
    /// output does not depend on the display or working-space defaults. Shared by the
    /// other deterministic renderers (thumbnails, legibility analysis, glass preview).
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Software CoreImage renderer with fixed sRGB working/output spaces. The software
    /// path guarantees byte-identical filter output (blur, bloom, gradients, masks)
    /// across machines and GPUs, which the baked-background determinism guarantee needs.
    private static let ciContext = CIContext(options: [
        .useSoftwareRenderer: true,
        .workingColorSpace: sRGB,
        .outputColorSpace: sRGB,
    ])

    /// Creates a premultiplied-RGBA8 bitmap context of an explicit pixel size in the fixed
    /// sRGB color space — the deterministic replacement for `NSImage.lockFocus`, whose
    /// backing scale otherwise follows the build machine's display. Shared by the other
    /// deterministic renderers so every offscreen pass agrees on format and color space.
    static func makeBitmapContext(pixelsWide: Int, pixelsHigh: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: max(pixelsWide, 1),
            height: max(pixelsHigh, 1),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    // MARK: - Composite Background

    /// Renders the composite background as a multi-representation TIFF holding a 1x and a
    /// 2x bitmap, both produced by deterministic `CGContext` rendering so the bytes are
    /// identical regardless of the build machine's display. The 2x representation carries
    /// the 1x point size so Finder treats it as `@2x`, giving crisp Retina backgrounds
    /// and correctly sized non-Retina ones from one file.
    static func renderBackgroundTIFF(
        configuration: DMGConfiguration,
        assetsDirectory: URL
    ) -> Data? {
        let pointSize = CGSize(width: configuration.window.width, height: configuration.window.height)
        guard pointSize.width > 0, pointSize.height > 0,
              let rep1 = renderRep(configuration: configuration, assetsDirectory: assetsDirectory, pointSize: pointSize, scale: 1),
              let rep2 = renderRep(configuration: configuration, assetsDirectory: assetsDirectory, pointSize: pointSize, scale: 2)
        else { return nil }

        return NSBitmapImageRep.representationOfImageReps(in: [rep1, rep2], using: .tiff, properties: [:])
    }

    /// Multi-representation (1x + 2x) `NSImage` for on-screen reuse such as thumbnails.
    /// The baked DMG background is produced by `renderBackgroundTIFF` directly.
    static func renderBackground(
        configuration: DMGConfiguration,
        assetsDirectory: URL
    ) -> NSImage? {
        let pointSize = CGSize(width: configuration.window.width, height: configuration.window.height)
        guard pointSize.width > 0, pointSize.height > 0,
              let rep1 = renderRep(configuration: configuration, assetsDirectory: assetsDirectory, pointSize: pointSize, scale: 1),
              let rep2 = renderRep(configuration: configuration, assetsDirectory: assetsDirectory, pointSize: pointSize, scale: 2)
        else { return nil }

        let image = NSImage(size: pointSize)
        image.addRepresentation(rep1)
        image.addRepresentation(rep2)
        return image
    }

    /// Renders the full composite at one scale into a fresh bitmap and wraps it as a
    /// representation whose reported point size is always the 1x size.
    private static func renderRep(
        configuration: DMGConfiguration,
        assetsDirectory: URL,
        pointSize: CGSize,
        scale: CGFloat
    ) -> NSBitmapImageRep? {
        let pixelsWide = Int((pointSize.width * scale).rounded())
        let pixelsHigh = Int((pointSize.height * scale).rounded())
        guard let context = makeBitmapContext(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh) else { return nil }

        context.scaleBy(x: scale, y: scale)
        renderComposite(into: context, configuration: configuration, assetsDirectory: assetsDirectory, scale: scale)

        guard let cgImage = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = pointSize
        return rep
    }

    /// Draws every layer of the composite into `context`, which is expected to be
    /// pre-scaled by `scale` so all geometry can be expressed in points. Readback-based
    /// effects (item-panel blur) receive `scale` to map point rects onto the pixel backing.
    private static func renderComposite(
        into context: CGContext,
        configuration: DMGConfiguration,
        assetsDirectory: URL,
        scale: CGFloat
    ) {
        // Bridge AppKit drawing (NSImage / NSAttributedString / NSBezierPath) onto this
        // CGContext. `flipped: false` keeps the y-up geometry the layer math assumes.
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        renderBeneathPanels(into: context, configuration: configuration) { layer in
            NSImage(contentsOf: assetsDirectory.appending(path: layer.imageName))
        }
        renderItemBackgrounds(
            items: configuration.items,
            iconSize: configuration.iconSize,
            in: context,
            canvasHeight: configuration.window.height,
            scale: scale
        )
    }

    /// Draws everything composited *beneath* item panels — base background, image
    /// layers, text layers, and SF symbols — in the exact order `renderComposite` uses,
    /// so panel blurs (baked and live preview) read from identical content.
    private static func renderBeneathPanels(
        into context: CGContext,
        configuration: DMGConfiguration,
        imageProvider: (BackgroundLayer) -> NSImage?
    ) {
        let width = configuration.window.width
        let height = configuration.window.height
        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)

        renderBaseBackground(context: context, configuration: configuration, rect: fullRect)

        if configuration.background.type == .image {
            renderImageLayers(
                context: context,
                layers: configuration.background.layers,
                canvasWidth: width,
                canvasHeight: height,
                imageProvider: imageProvider
            )
        }

        renderTextLayers(configuration.textLayers, in: context, canvasHeight: height)
        renderSFSymbolLayers(configuration.sfSymbolLayers, in: context, canvasHeight: height)
    }

    // MARK: - Panel Backdrop (live preview)

    /// Renders the composite that sits beneath item panels at `scale`× pixel density,
    /// sourcing layer images from memory instead of an on-disk assets directory.
    ///
    /// This is the image the public glass preview (`CanvasBackdropBlurView`) crops and
    /// blurs. The panels themselves are deliberately excluded: in the built DMG each
    /// panel's blur reads only the content composited before `renderItemBackgrounds`,
    /// so blurring this backdrop matches what the baked background shows.
    static func renderPanelBackdrop(
        configuration: DMGConfiguration,
        layerImages: [UUID: NSImage],
        scale: CGFloat
    ) -> CGImage? {
        compositeImage(
            configuration: configuration,
            layerImages: layerImages,
            scale: scale,
            includePanels: false
        )
    }

    // MARK: - Analysis Composite

    /// Renders the complete composite — everything `renderBeneathPanels` draws plus
    /// the baked item panels — from in-memory layer images at `scale`× pixel density.
    ///
    /// This is the exact content the built DMG's background shows behind Finder's
    /// labels, which is what the label legibility analyzer samples: enabled item
    /// panels are the primary remediation for an unreadable label, so they must
    /// count toward the label's backdrop.
    static func renderAnalysisComposite(
        configuration: DMGConfiguration,
        layerImages: [UUID: NSImage],
        scale: CGFloat
    ) -> CGImage? {
        compositeImage(
            configuration: configuration,
            layerImages: layerImages,
            scale: scale,
            includePanels: true
        )
    }

    /// Renders the composite from in-memory layer images into a fresh `scale`× bitmap.
    /// `renderBeneathPanels` always runs; `includePanels` adds the baked item panels on
    /// top, which is the only difference between the backdrop and analysis composites.
    private static func compositeImage(
        configuration: DMGConfiguration,
        layerImages: [UUID: NSImage],
        scale: CGFloat,
        includePanels: Bool
    ) -> CGImage? {
        let pointSize = CGSize(width: configuration.window.width, height: configuration.window.height)
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }

        let pixelsWide = Int((pointSize.width * scale).rounded())
        let pixelsHigh = Int((pointSize.height * scale).rounded())
        guard let context = makeBitmapContext(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh) else { return nil }
        context.scaleBy(x: scale, y: scale)

        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        renderBeneathPanels(into: context, configuration: configuration) { layerImages[$0.id] }
        if includePanels {
            renderItemBackgrounds(
                items: configuration.items,
                iconSize: configuration.iconSize,
                in: context,
                canvasHeight: configuration.window.height,
                scale: scale
            )
        }

        return context.makeImage()
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
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        imageProvider: (BackgroundLayer) -> NSImage?
    ) {
        for layer in layers {
            guard let layerImage = imageProvider(layer) else { continue }

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
        in context: CGContext,
        canvasHeight: CGFloat
    ) {
        for symbolLayer in symbolLayers {
            let config = NSImage.SymbolConfiguration(
                pointSize: symbolLayer.pointSize,
                weight: symbolLayer.weight.nsFontWeight,
                scale: .medium
            )
            guard let symbolImage = NSImage(
                systemSymbolName: symbolLayer.symbolName,
                accessibilityDescription: nil
            )?.withSymbolConfiguration(config) else { continue }

            let symbolSize = symbolImage.size
            let originX = symbolLayer.position.x - symbolSize.width / 2
            let originY = canvasHeight - symbolLayer.position.y - symbolSize.height / 2
            let rect = NSRect(x: originX, y: originY, width: symbolSize.width, height: symbolSize.height)

            let color = NSColor(
                srgbRed: symbolLayer.color.red,
                green: symbolLayer.color.green,
                blue: symbolLayer.color.blue,
                alpha: 1
            )

            // Draw the template glyph then tint it in place inside a transparency layer,
            // so rasterization follows this context's scale (deterministic) rather than an
            // intermediate NSImage whose backing scale tracks the display.
            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            symbolImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            color.set()
            rect.fill(using: .sourceAtop)
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    // MARK: - Item Backgrounds

    /// Dimensions match CanvasView: icon cell (iconSize + 20) + text gap (4) + text (~20)
    private static func renderItemBackgrounds(
        items: [CanvasItem],
        iconSize: CGFloat,
        in context: CGContext,
        canvasHeight: CGFloat,
        scale: CGFloat
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
            renderItemPanel(bg: bg, rect: bgRect, in: context, scale: scale)

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
        in context: CGContext,
        scale: CGFloat
    ) {
        guard bg.enabled else { return }

        let cornerRadius = bg.cornerRadius

        if bg.blurRadius > 0 {
            if bg.blurFeather > 0 {
                renderFeatheredBlurRegion(
                    context: context, rect: rect, cornerRadius: cornerRadius,
                    blurRadius: bg.blurRadius, feather: bg.blurFeather, scale: scale
                )
            } else {
                renderBlurredRegion(
                    context: context, rect: rect, cornerRadius: cornerRadius,
                    blurRadius: bg.blurRadius, scale: scale
                )
            }
        }

        let bgColor = CGColor(
            srgbRed: bg.color.red, green: bg.color.green,
            blue: bg.color.blue, alpha: bg.opacity
        )

        if bg.blurFeather > 0 {
            guard let maskImage = generateContourMask(
                size: rect.size, cornerRadius: cornerRadius, feather: bg.blurFeather, scale: scale
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
        let pixelsWide = Int(size.width.rounded())
        let pixelsHigh = Int(size.height.rounded())
        guard let context = makeBitmapContext(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return image }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        guard let resized = context.makeImage() else { return image }
        return NSImage(cgImage: resized, size: size)
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

        // 1. Create white rounded rect mask on black background (deterministic bitmap).
        let bounds = CGRect(origin: .zero, size: size)
        guard let maskContext = makeBitmapContext(
            pixelsWide: Int(size.width.rounded()),
            pixelsHigh: Int(size.height.rounded())
        ) else { return nil }
        maskContext.setFillColor(CGColor(gray: 0, alpha: 1))
        maskContext.fill(bounds)
        maskContext.setFillColor(CGColor(gray: 1, alpha: 1))
        maskContext.addPath(CGPath(
            roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
        ))
        maskContext.fillPath()

        guard let maskCG = maskContext.makeImage() else { return nil }
        let ciMask = CIImage(cgImage: maskCG)

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
        blurRadius: CGFloat,
        scale: CGFloat
    ) {
        // `context.makeImage()` returns the full backing at pixel resolution, so the
        // point-space panel rect and blur radius are mapped into pixels before cropping
        // and blurring, then the result is drawn back in points under the scaled CTM.
        guard let currentBitmap = context.makeImage() else { return }
        let ciImage = CIImage(cgImage: currentBitmap)

        let rectPx = rect.applying(CGAffineTransform(scaleX: scale, y: scale))
        let paddingPx = blurRadius * scale * 3
        let expandedPx = rectPx.insetBy(dx: -paddingPx, dy: -paddingPx)
        let cropped = ciImage.cropped(to: expandedPx)

        let filter = CIFilter.gaussianBlur()
        filter.inputImage = cropped
        filter.radius = Float(blurRadius * scale)

        guard let blurred = filter.outputImage?.cropped(to: rectPx),
              let cgBlurred = ciContext.createCGImage(blurred, from: rectPx) else { return }

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
        feather: CGFloat,
        scale: CGFloat
    ) {
        guard let currentBitmap = context.makeImage() else { return }
        let ciImage = CIImage(cgImage: currentBitmap)

        let rectPx = rect.applying(CGAffineTransform(scaleX: scale, y: scale))
        let paddingPx = blurRadius * scale * 3
        let expandedPx = rectPx.insetBy(dx: -paddingPx, dy: -paddingPx)
        let cropped = ciImage.cropped(to: expandedPx)

        // Contour-following mask at pixel resolution so it aligns with the pixel-space blur.
        guard let maskImage = generateContourMask(
            size: rect.size,
            cornerRadius: cornerRadius,
            feather: feather,
            scale: scale
        ) else { return }

        let ciMask = CIImage(cgImage: maskImage)
            .transformed(by: CGAffineTransform(translationX: rectPx.origin.x, y: rectPx.origin.y))

        let filter = CIFilter.maskedVariableBlur()
        filter.inputImage = cropped
        filter.mask = ciMask.cropped(to: expandedPx)
        filter.radius = Float(blurRadius * scale)

        guard let blurred = filter.outputImage?.cropped(to: rectPx),
              let cgBlurred = ciContext.createCGImage(blurred, from: rectPx) else { return }

        // Draw with the same contour mask for the edge fade. `clip(to:mask:)` stretches the
        // mask image over `rect`, so the pixel-resolution mask maps correctly in point space.
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
        feather: CGFloat,
        scale: CGFloat = 1
    ) -> CGImage? {
        let pixelsWide = Int((size.width * scale).rounded())
        let pixelsHigh = Int((size.height * scale).rounded())
        guard let ctx = makeBitmapContext(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        let bounds = CGRect(origin: .zero, size: size)
        let featherPx = min(size.width, size.height) * feather * 0.5
        let insetRect = bounds.insetBy(dx: featherPx, dy: featherPx)
        let insetCR = max(cornerRadius - featherPx, 0)

        // Draw white rounded rect on black background, then blur to create the feathered edge.
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(bounds)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(CGPath(roundedRect: insetRect, cornerWidth: insetCR, cornerHeight: insetCR, transform: nil))
        ctx.fillPath()

        guard let base = ctx.makeImage() else { return nil }

        let extentPx = CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = CIImage(cgImage: base)
        blur.radius = Float(featherPx * scale)
        guard let blurred = blur.outputImage?.cropped(to: extentPx) else { return nil }

        return ciContext.createCGImage(blurred, from: extentPx)
    }
}
