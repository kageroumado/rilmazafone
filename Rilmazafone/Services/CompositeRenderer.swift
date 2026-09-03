import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

nonisolated enum CompositeRenderer {
    /// Fixed sRGB color space used for every offscreen bitmap and CoreImage pass, so
    /// output does not depend on the display or working-space defaults. Shared by the
    /// other deterministic renderers (thumbnails, legibility analysis, canvas panels).
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
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
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
        assetsDirectory: URL,
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
        assetsDirectory: URL,
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
        scale: CGFloat,
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
        scale: CGFloat,
    ) {
        // Bridge AppKit drawing (NSImage / NSAttributedString / NSBezierPath) onto this
        // CGContext. `flipped: false` keeps the y-up geometry the layer math assumes.
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        renderBeneathPanels(into: context, configuration: configuration, excluding: nil, scale: scale) { layer in
            NSImage(contentsOf: assetsDirectory.appending(path: layer.imageName))
        }
        renderItemBackgrounds(
            items: configuration.items,
            iconSize: configuration.iconSize,
            in: context,
            canvasHeight: configuration.window.height,
            scale: scale,
        )
        renderGrainFinish(into: context, configuration: configuration, scale: scale)
    }

    /// Lays the document's grain over the finished composite — after the panels, because
    /// grain is a film over the whole background rather than something the panels' glass
    /// picks up and blurs.
    private static func renderGrainFinish(
        into context: CGContext,
        configuration: DMGConfiguration,
        scale: CGFloat,
    ) {
        guard let grain = configuration.background.grain, grain.enabled else { return }
        renderGrain(
            context: context,
            grain: grain,
            rect: CGRect(
                x: 0, y: 0,
                width: configuration.window.width,
                height: configuration.window.height,
            ),
            scale: scale,
        )
    }

    /// Draws everything composited *beneath* item panels — base background, image
    /// layers, text layers, and SF symbols — in the exact order `renderComposite` uses,
    /// so panel blurs (baked and live preview) read from identical content.
    ///
    /// - Parameter excluding: A layer the canvas is drawing live because it is selected,
    ///   and which must therefore be left out of the composite beneath it. The build
    ///   passes `nil`; nothing is ever excluded from a baked background.
    private static func renderBeneathPanels(
        into context: CGContext,
        configuration: DMGConfiguration,
        excluding: UUID?,
        scale: CGFloat,
        imageProvider: (BackgroundLayer) -> NSImage?,
    ) {
        let width = configuration.window.width
        let height = configuration.window.height
        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)

        renderBaseBackground(context: context, configuration: configuration, rect: fullRect, scale: scale)

        if configuration.background.type == .image {
            renderImageLayers(
                context: context,
                layers: configuration.background.layers.filter { $0.id != excluding },
                canvasWidth: width,
                canvasHeight: height,
                scale: scale,
                imageProvider: imageProvider,
            )
        }

        renderTextLayers(
            configuration.textLayers.filter { $0.id != excluding },
            in: context, canvasHeight: height,
        )
        renderSFSymbolLayers(
            configuration.sfSymbolLayers.filter { $0.id != excluding },
            in: context, canvasHeight: height,
        )
    }

    // MARK: - Canvas Composite

    /// Everything the canvas paints beneath the icons: base background, image layers,
    /// type, symbols, item panels, and grain — the complete composite the build bakes.
    ///
    /// Panels belong in here rather than as views layered over a panel-free backdrop.
    /// Each one's glass blurs whatever lies beneath it, and beneath can be another
    /// panel: a blur widens a panel's render region far past its own rectangle, so on a
    /// normal three-item layout every region overlaps every other. Composited
    /// separately they either paint over one another or blur a background missing the
    /// panel actually under them.
    ///
    /// - Parameter excluding: A layer the canvas draws live because it is selected,
    ///   left out here so it is not drawn twice.
    static func renderCanvasComposite(
        configuration: DMGConfiguration,
        layerImages: [UUID: NSImage],
        scale: CGFloat,
        excluding: UUID? = nil,
    ) -> CGImage? {
        compositeImage(
            configuration: configuration,
            layerImages: layerImages,
            scale: scale,
            includePanels: true,
            excluding: excluding,
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
        scale: CGFloat,
    ) -> CGImage? {
        compositeImage(
            configuration: configuration,
            layerImages: layerImages,
            scale: scale,
            includePanels: true,
        )
    }

    /// Renders the composite from in-memory layer images into a fresh `scale`× bitmap.
    /// `renderBeneathPanels` always runs; `includePanels` adds the baked item panels on
    /// top, which is the only difference between the backdrop and analysis composites.
    private static func compositeImage(
        configuration: DMGConfiguration,
        layerImages: [UUID: NSImage],
        scale: CGFloat,
        includePanels: Bool,
        excluding: UUID? = nil,
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

        renderBeneathPanels(
            into: context, configuration: configuration, excluding: excluding, scale: scale,
        ) { layerImages[$0.id] }

        // The backdrop stops short of the panels and the grain on purpose: it is the
        // content a panel's blur reads, and in the baked background that blur sees
        // neither. The analysis composite goes all the way, because it stands in for
        // what Finder puts behind a label.
        if includePanels {
            renderItemBackgrounds(
                items: configuration.items,
                iconSize: configuration.iconSize,
                in: context,
                canvasHeight: configuration.window.height,
                scale: scale,
            )
            renderGrainFinish(into: context, configuration: configuration, scale: scale)
        }

        return context.makeImage()
    }

    // MARK: - Base Background

    private static func renderBaseBackground(
        context: CGContext,
        configuration: DMGConfiguration,
        rect: CGRect,
        scale: CGFloat,
    ) {
        switch configuration.background.type {
        case .none:
            context.clear(rect)
        case .color, .image:
            let bgColor = configuration.background.color
            context.setFillColor(CGColor(
                srgbRed: bgColor.red, green: bgColor.green, blue: bgColor.blue, alpha: 1,
            ))
            context.fill(rect)
        case .gradient:
            if let grad = configuration.background.gradient {
                renderGradient(context: context, gradient: grad, rect: rect)
            } else {
                context.clear(rect)
            }
        case .mesh:
            if let mesh = configuration.background.mesh {
                renderMesh(context: context, mesh: mesh, rect: rect, scale: scale)
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
        scale: CGFloat,
        imageProvider: (BackgroundLayer) -> NSImage?,
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
                displaySize: CGSize(width: displayWidth, height: displayHeight),
                scale: scale,
            )

            let originX = layer.position.x - displayWidth / 2
            let originY = canvasHeight - layer.position.y - displayHeight / 2

            processedImage.draw(
                in: NSRect(x: originX, y: originY, width: displayWidth, height: displayHeight),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0,
            )
        }
    }

    // MARK: - Text Layers

    private static func renderTextLayers(
        _ textLayers: [TextLayerConfiguration],
        in _: CGContext,
        canvasHeight: CGFloat,
    ) {
        for textLayer in textLayers {
            let string = attributedString(for: textLayer)
            let size = string.size()
            let drawX = textLayer.position.x - size.width / 2
            let drawY = canvasHeight - textLayer.position.y - size.height / 2
            string.draw(at: NSPoint(x: drawX, y: drawY))
        }
    }

    // MARK: - Layer Metrics

    /// The font a text layer renders with, resolving family, size, and bold/italic traits.
    static func font(for layer: TextLayerConfiguration) -> NSFont {
        let base = NSFont(name: layer.fontFamily, size: layer.fontSize)
            ?? NSFont.systemFont(ofSize: layer.fontSize)

        var traits: NSFontDescriptor.SymbolicTraits = []
        if layer.isBold {
            traits.insert(.bold)
        }
        if layer.isItalic {
            traits.insert(.italic)
        }
        guard !traits.isEmpty else { return base }

        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: layer.fontSize) ?? base
    }

    /// The drawn form of a text layer. Its `size()` is the layer's footprint in canvas
    /// points, which the canvas uses to place the layer's selection and drag target so
    /// the handle covers exactly what the background shows.
    static func attributedString(for layer: TextLayerConfiguration) -> NSAttributedString {
        NSAttributedString(string: layer.text, attributes: [
            .font: font(for: layer),
            .foregroundColor: NSColor(
                srgbRed: layer.color.red, green: layer.color.green, blue: layer.color.blue, alpha: 1,
            ),
        ])
    }

    /// The template glyph an SF Symbol layer renders, at its configured size and weight.
    static func symbolImage(for layer: SFSymbolLayerConfiguration) -> NSImage? {
        NSImage(systemSymbolName: layer.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: layer.pointSize, weight: layer.weight.nsFontWeight, scale: .medium,
            ))
    }

    // MARK: - SF Symbol Layers

    private static func renderSFSymbolLayers(
        _ symbolLayers: [SFSymbolLayerConfiguration],
        in context: CGContext,
        canvasHeight: CGFloat,
    ) {
        for symbolLayer in symbolLayers {
            guard let symbolImage = symbolImage(for: symbolLayer) else { continue }

            let symbolSize = symbolImage.size
            let originX = symbolLayer.position.x - symbolSize.width / 2
            let originY = canvasHeight - symbolLayer.position.y - symbolSize.height / 2
            let rect = NSRect(x: originX, y: originY, width: symbolSize.width, height: symbolSize.height)

            let color = NSColor(
                srgbRed: symbolLayer.color.red,
                green: symbolLayer.color.green,
                blue: symbolLayer.color.blue,
                alpha: 1,
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

    private static func renderItemBackgrounds(
        items: [CanvasItem],
        iconSize: CGFloat,
        in context: CGContext,
        canvasHeight: CGFloat,
        scale: CGFloat,
    ) {
        for item in items {
            guard let bg = item.background, bg.draws else { continue }

            let bgRect = ItemGeometry.panelRectFlipped(
                center: item.position,
                iconSize: iconSize,
                padding: bg.padding,
                canvasHeight: canvasHeight,
            )
            renderItemLayers(bg: bg, rect: bgRect, in: context, scale: scale)
        }
    }

    /// Draws one panel's shadow, body, and bevel in that order. The single place the
    /// panel's appearance is defined: the canvas preview renders through here too, so
    /// what the editor shows and what the DMG bakes cannot drift apart.
    private static func renderItemLayers(
        bg: ItemBackground,
        rect: CGRect,
        in context: CGContext,
        scale: CGFloat,
    ) {
        renderItemShadow(bg: bg, rect: rect, in: context, scale: scale)
        renderItemPanel(bg: bg, rect: rect, in: context, scale: scale)

        if let bevel = bg.bevel, bevel.enabled {
            renderBevel(
                context: context, rect: rect,
                cornerRadius: bg.cornerRadius, bevel: bevel, scale: scale,
            )
        }

        if let glass = bg.glass, glass.enabled {
            renderGlassEdge(
                context: context, glass: glass, rect: rect,
                cornerRadius: bg.cornerRadius, scale: scale,
            )
        }
    }

    private static func renderItemShadow(
        bg: ItemBackground,
        rect: CGRect,
        in context: CGContext,
        scale: CGFloat,
    ) {
        guard let shadow = bg.shadow, shadow.enabled else { return }

        let shadowColor = CGColor(
            srgbRed: shadow.color.red,
            green: shadow.color.green,
            blue: shadow.color.blue,
            alpha: shadow.opacity,
        )
        let shadowPath = CGPath(
            roundedRect: rect,
            cornerWidth: bg.cornerRadius,
            cornerHeight: bg.cornerRadius,
            transform: nil,
        )

        // Use transparency layer so we can erase the casting shape,
        // leaving only the shadow visible outside the panel area.
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        // Core Graphics reads the shadow offset and blur in device space, ignoring the
        // CTM, so both are scaled by hand — otherwise the @2x representation would carry
        // a shadow half as far and half as soft as the @1x one drawn from the same points.
        context.setShadow(
            offset: CGSize(width: shadow.offsetX * scale, height: -shadow.offsetY * scale),
            blur: shadow.radius * scale,
            color: shadowColor,
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
        scale: CGFloat,
    ) {
        guard bg.enabled else { return }

        let cornerRadius = bg.cornerRadius

        // Glass lifts the saturation of what shows through it; without a glass edge the
        // body passes the background's own color straight through.
        let saturation = bg.glass?.enabled == true ? (bg.glass?.saturation ?? 1) : 1

        if bg.blurRadius > 0 {
            if bg.blurFeather > 0 {
                renderFeatheredBlurRegion(
                    context: context, rect: rect, cornerRadius: cornerRadius,
                    blurRadius: bg.blurRadius, feather: bg.blurFeather,
                    saturation: saturation, scale: scale,
                )
            } else {
                renderBlurredRegion(
                    context: context, rect: rect, cornerRadius: cornerRadius,
                    blurRadius: bg.blurRadius, saturation: saturation, scale: scale,
                )
            }
        }

        let bgColor = CGColor(
            srgbRed: bg.color.red, green: bg.color.green,
            blue: bg.color.blue, alpha: bg.opacity,
        )

        if bg.blurFeather > 0 {
            guard let maskImage = generateContourMask(
                size: rect.size, cornerRadius: cornerRadius, feather: bg.blurFeather, scale: scale,
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
                transform: nil,
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
        displaySize: CGSize,
        scale: CGFloat = 1,
    ) -> NSImage {
        let targetPixelSize = CGSize(
            width: (displaySize.width * scale).rounded(),
            height: (displaySize.height * scale).rounded(),
        )
        let source: NSImage = if abs(image.size.width - targetPixelSize.width) > 1
            || abs(image.size.height - targetPixelSize.height) > 1 {
            resizeImage(image, to: targetPixelSize)
        } else {
            image
        }

        guard let tiffData = source.tiffRepresentation,
              var ciImage = CIImage(data: tiffData) else { return source }
        let extent = ciImage.extent

        // 1. Blur (variable or gaussian, not both)
        if let vb = layer.variableBlur {
            ciImage = applyVariableBlur(to: ciImage, config: vb, scale: scale)
        } else if layer.blurRadius > 0 {
            let f = CIFilter.gaussianBlur()
            f.inputImage = ciImage
            f.radius = Float(layer.blurRadius * scale)
            if let out = f.outputImage {
                ciImage = out.cropped(to: extent)
            }
        }

        // 2. Color adjustments
        if let ca = layer.colorAdjustments {
            ciImage = applyColorAdjustments(to: ciImage, adjustments: ca)
        }

        // 3. Gradient map
        if let map = layer.gradientMap {
            ciImage = applyGradientMap(to: ciImage, config: map).cropped(to: extent)
        }

        // 4. Vignette
        if let v = layer.vignette {
            let f = CIFilter.vignette()
            f.inputImage = ciImage
            f.intensity = Float(v.intensity)
            f.radius = Float(v.radius * scale)
            if let out = f.outputImage {
                ciImage = out.cropped(to: extent)
            }
        }

        // 5. Bloom
        if let b = layer.bloom {
            let f = CIFilter.bloom()
            f.inputImage = ciImage
            f.intensity = Float(b.intensity)
            f.radius = Float(b.radius * scale)
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
            if let out = f.outputImage {
                result = out.cropped(to: extent)
            }
        }
        if ca.hueRotation != 0 {
            let f = CIFilter.hueAdjust()
            f.inputImage = result
            f.angle = Float(ca.hueRotation * .pi / 180)
            if let out = f.outputImage {
                result = out.cropped(to: extent)
            }
        }
        if ca.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = result
            f.ev = Float(ca.exposure)
            if let out = f.outputImage {
                result = out.cropped(to: extent)
            }
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

    static func applyVariableBlur(to image: CIImage, config: VariableBlurConfiguration, scale: CGFloat = 1) -> CIImage {
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
                y: cy + sin(radians + .pi) * halfDiag,
            )
            let point1 = CGPoint(
                x: cx + cos(radians) * halfDiag,
                y: cy + sin(radians) * halfDiag,
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
                y: extent.height * config.centerY,
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
        filter.radius = Float(config.radius * scale)
        return filter.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: - Gradient Rendering

    static func renderGradient(
        context: CGContext,
        gradient: GradientConfiguration,
        rect: CGRect,
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
                alpha: 1,
            ))
            locations.append(stop.location)
        }
        guard let cgGradient = CGGradient(
            colorsSpace: colorSpace,
            colors: cgColors as CFArray,
            locations: &locations,
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
                y: cy - sin(radians + .pi) * halfDiag, // y-up in CG
            )
            let endPoint = CGPoint(
                x: cx + cos(radians) * halfDiag,
                y: cy - sin(radians) * halfDiag,
            )
            context.drawLinearGradient(
                cgGradient,
                start: startPoint,
                end: endPoint,
                options: [.drawsAfterEndLocation, .drawsBeforeStartLocation],
            )

        case .radial:
            let center = CGPoint(
                x: rect.width * gradient.centerX,
                y: rect.height * (1 - gradient.centerY), // flip y for CG
            )
            let r0 = gradient.startRadius * rect.width
            let r1 = gradient.endRadius * rect.width
            context.drawRadialGradient(
                cgGradient,
                startCenter: center,
                startRadius: r0,
                endCenter: center,
                endRadius: r1,
                options: [.drawsAfterEndLocation],
            )
        }

        context.restoreGState()
    }

    // MARK: - Bevel Rendering

    /// Renders the panel's bevel as a soft-light overlay of its rounded rectangle: a
    /// shaded relief along the edge, transparent outside the shape and neutral mid-gray
    /// across the flat interior, so compositing it changes the edge and nothing else.
    ///
    /// - Parameter scale: Pixels per point, so the relief is drawn on the same pixel grid
    ///   as the background it lands in rather than being resampled up from 1×.
    static func renderBevelImage(
        size: CGSize,
        cornerRadius: CGFloat,
        bevel: BevelConfiguration,
        scale: CGFloat = 1,
    ) -> CGImage? {
        let pixelsWide = Int((size.width * scale).rounded())
        let pixelsHigh = Int((size.height * scale).rounded())
        guard pixelsWide > 0, pixelsHigh > 0 else { return nil }

        // Two CoreImage passes and a 128×128 shading sphere, all of it a pure function of
        // the arguments — and every panel in a document usually carries the same bevel.
        // Rendered fresh each time it dominates the cost of compositing a canvas.
        let key = BevelKey(
            pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            cornerRadius: cornerRadius, bevel: bevel,
        )
        if let cached = bevelCache.value(for: key) {
            return cached
        }

        let bounds = CGRect(origin: .zero, size: size)
        let shape = CGPath(
            roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil,
        )

        // 1. White rounded rect on black — the mask the height field is raised from.
        guard let maskContext = makeBitmapContext(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh) else { return nil }
        maskContext.scaleBy(x: scale, y: scale)
        maskContext.setFillColor(CGColor(gray: 0, alpha: 1))
        maskContext.fill(bounds)
        maskContext.setFillColor(CGColor(gray: 1, alpha: 1))
        maskContext.addPath(shape)
        maskContext.fillPath()

        guard let maskCG = maskContext.makeImage() else { return nil }
        let ciMask = CIImage(cgImage: maskCG)

        // 2. Raise the mask into a height field and light it through the shading sphere.
        let heightField = CIFilter.heightFieldFromMask()
        heightField.inputImage = ciMask
        heightField.radius = Float(bevel.depth * scale)
        guard let heightOutput = heightField.outputImage else { return nil }

        let shaded = CIFilter.shadedMaterial()
        shaded.inputImage = heightOutput
        shaded.shadingImage = generateShadingSphere(lightAngle: bevel.lightAngle, size: 128)
        shaded.scale = Float(bevel.intensity * 20)
        guard let shadedOutput = shaded.outputImage?.cropped(to: ciMask.extent),
              let shadedCG = ciContext.createCGImage(shadedOutput, from: ciMask.extent)
        else { return nil }

        // 3. Clip the shading to the panel's own shape. `CIShadedMaterial` returns an
        // opaque square, and a soft-light overlay of that square tints the full bounding
        // box — which is how the corner radius went missing from built backgrounds.
        guard let output = makeBitmapContext(pixelsWide: pixelsWide, pixelsHigh: pixelsHigh) else { return nil }
        output.scaleBy(x: scale, y: scale)
        output.addPath(shape)
        output.clip()
        output.draw(shadedCG, in: bounds)

        let image = output.makeImage()
        if let image {
            bevelCache.insert(image, for: key)
        }
        return image
    }

    private struct BevelKey: Hashable {
        let pixelsWide: Int
        let pixelsHigh: Int
        let cornerRadius: CGFloat
        let bevel: BevelConfiguration
    }

    private static let bevelCache = ImageCache<BevelKey>(capacity: 24)

    /// The lit hemisphere is a pure function of the light angle and is rebuilt pixel by
    /// pixel; every panel with the same angle wants the same one.
    private static let shadingSphereCache = ImageCache<Int>(capacity: 12)

    static func renderBevel(
        context: CGContext,
        rect: CGRect,
        cornerRadius: CGFloat,
        bevel: BevelConfiguration,
        scale: CGFloat,
    ) {
        guard let bevelImage = renderBevelImage(
            size: rect.size,
            cornerRadius: cornerRadius,
            bevel: bevel,
            scale: scale,
        ) else { return }

        context.saveGState()
        context.setBlendMode(.softLight)
        context.draw(bevelImage, in: rect)
        context.restoreGState()
    }

    /// The lit hemisphere `CIShadedMaterial` indexes by surface normal.
    ///
    /// The whole response curve is biased so a surface facing the viewer reads exactly
    /// mid-gray, which is the identity under soft light: the relief then lights and
    /// shades the panel's edge while leaving its flat interior untouched.
    static func generateShadingSphere(lightAngle: CGFloat, size: Int = 128) -> CIImage {
        let key = Int((lightAngle * 100).rounded()) &* 1_000 &+ size
        if let cached = shadingSphereCache.value(for: key) {
            return CIImage(cgImage: cached)
        }

        let radians = lightAngle * .pi / 180
        let lightX = cos(radians)
        let lightY = sin(radians)
        let lightZ: CGFloat = 0.5
        let lightLen = sqrt(lightX * lightX + lightY * lightY + lightZ * lightZ)
        let lx = lightX / lightLen
        let ly = lightY / lightLen
        let lz = lightZ / lightLen

        func response(toLight dot: CGFloat) -> CGFloat {
            let diffuse = max(dot, 0)
            return 0.3 + 0.5 * diffuse + 0.2 * pow(diffuse, 4)
        }

        let neutral: CGFloat = 0.5
        let bias = neutral - response(toLight: lz)

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
                    intensity = min(max(response(toLight: dx * lx + dy * ly + nz * lz) + bias, 0), 1)
                } else {
                    intensity = neutral
                }

                let idx = (y * size + x) * 4
                let byte = UInt8((intensity * 255).rounded())
                pixels[idx] = byte // R
                pixels[idx + 1] = byte // G
                pixels[idx + 2] = byte // B
                pixels[idx + 3] = 255 // A
            }
        }

        let data = Data(pixels)
        let image = CIImage(
            bitmapData: data,
            bytesPerRow: size * 4,
            size: CGSize(width: size, height: size),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
        )
        if let cgImage = makeImage(rgba: pixels, pixelsWide: size, pixelsHigh: size) {
            shadingSphereCache.insert(cgImage, for: key)
        }
        return image
    }

    // MARK: - Blur Helpers

    static func renderBlurredRegion(
        context: CGContext,
        rect: CGRect,
        cornerRadius: CGFloat,
        blurRadius: CGFloat,
        saturation: CGFloat = 1,
        scale: CGFloat,
    ) {
        // `context.makeImage()` returns the full backing at pixel resolution, so the
        // point-space panel rect and blur radius are mapped into pixels before cropping
        // and blurring, then the result is drawn back in points under the scaled CTM.
        // The mapping goes through the CTM rather than `scale` alone, because the live
        // panel preview renders into a translated context covering just one panel.
        guard let currentBitmap = context.makeImage() else { return }
        let ciImage = CIImage(cgImage: currentBitmap)

        let rectPx = rect.applying(context.ctm)
        let paddingPx = blurRadius * scale * 3
        let expandedPx = rectPx.insetBy(dx: -paddingPx, dy: -paddingPx)
        let cropped = ciImage.cropped(to: expandedPx)

        let filter = CIFilter.gaussianBlur()
        filter.inputImage = cropped
        filter.radius = Float(blurRadius * scale)

        guard let blurred = filter.outputImage?.cropped(to: rectPx),
              let saturated = applySaturation(saturation, to: blurred, extent: rectPx),
              let cgBlurred = ciContext.createCGImage(saturated, from: rectPx) else { return }

        let path = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil,
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
        saturation: CGFloat = 1,
        scale: CGFloat,
    ) {
        guard let currentBitmap = context.makeImage() else { return }
        let ciImage = CIImage(cgImage: currentBitmap)

        let rectPx = rect.applying(context.ctm)
        let paddingPx = blurRadius * scale * 3
        let expandedPx = rectPx.insetBy(dx: -paddingPx, dy: -paddingPx)
        let cropped = ciImage.cropped(to: expandedPx)

        // Contour-following mask at pixel resolution so it aligns with the pixel-space blur.
        guard let maskImage = generateContourMask(
            size: rect.size,
            cornerRadius: cornerRadius,
            feather: feather,
            scale: scale,
        ) else { return }

        let ciMask = CIImage(cgImage: maskImage)
            .transformed(by: CGAffineTransform(translationX: rectPx.origin.x, y: rectPx.origin.y))

        let filter = CIFilter.maskedVariableBlur()
        filter.inputImage = cropped
        filter.mask = ciMask.cropped(to: expandedPx)
        filter.radius = Float(blurRadius * scale)

        guard let blurred = filter.outputImage?.cropped(to: rectPx),
              let saturated = applySaturation(saturation, to: blurred, extent: rectPx),
              let cgBlurred = ciContext.createCGImage(saturated, from: rectPx) else { return }

        // Draw with the same contour mask for the edge fade. `clip(to:mask:)` stretches the
        // mask image over `rect`, so the pixel-resolution mask maps correctly in point space.
        context.saveGState()
        context.clip(to: rect, mask: maskImage)
        context.draw(cgBlurred, in: rect)
        context.restoreGState()
    }

    /// Lifts an image's saturation, leaving it untouched at 1.
    private static func applySaturation(_ saturation: CGFloat, to image: CIImage, extent: CGRect) -> CIImage? {
        guard saturation != 1 else { return image }
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.saturation = Float(saturation)
        return filter.outputImage?.cropped(to: extent)
    }

    /// Generates a contour-following mask: white at center, black at edges,
    /// following the rounded rectangle shape.
    static func generateContourMask(
        size: CGSize,
        cornerRadius: CGFloat,
        feather: CGFloat,
        scale: CGFloat = 1,
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
