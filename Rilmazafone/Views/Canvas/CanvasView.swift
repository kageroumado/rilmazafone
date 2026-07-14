import SwiftUI
import UniformTypeIdentifiers

// MARK: - Alignment Guides

struct AlignmentGuides: Equatable {
    var verticalLines: Set<CGFloat> = []
    var horizontalLines: Set<CGFloat> = []
    static let none = AlignmentGuides()
}

struct CanvasView: View {
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager
    @Binding var selectedItemID: UUID?
    @Binding var zoom: CGFloat
    @Binding var isFitToWindow: Bool
    let prefersDarkAppearance: Bool

    @State private var isFileImporterPresented = false
    @State private var titleBarIcon: NSImage?
    @State private var activeGuides = AlignmentGuides.none
    @State private var panelBackdrop: CanvasBackdrop?

    var body: some View {
        GeometryReader { geometry in
            let fitZoom = fitToWindowZoom(viewSize: geometry.size)

            ScrollView([.horizontal, .vertical]) {
                ZStack {
                    canvasBackground

                    let ez = effectiveZoom(fitZoom: fitZoom)
                    let totalHeight = windowHeight + Self.titleBarHeight

                    dmgWindowPreview
                        .frame(
                            width: windowWidth,
                            height: totalHeight
                        )
                        .scaleEffect(ez)
                        .frame(
                            width: windowWidth * ez,
                            height: totalHeight * ez
                        )
                }
                .frame(
                    width: max(
                        geometry.size.width,
                        windowWidth * effectiveZoom(fitZoom: fitZoom) + 80
                    ),
                    height: max(
                        geometry.size.height,
                        (windowHeight + Self.titleBarHeight) * effectiveZoom(fitZoom: fitZoom) + 80
                    )
                )
            }
            .onAppear {
                if isFitToWindow {
                    zoom = fitZoom
                }
            }
            .onChange(of: geometry.size) {
                if isFitToWindow {
                    zoom = fitToWindowZoom(viewSize: geometry.size)
                }
            }
        }
        .overlay {
            if document.configuration.items.isEmpty,
               document.configuration.background.layers.isEmpty,
               document.configuration.textLayers.isEmpty,
               document.configuration.sfSymbolLayers.isEmpty {
                EmptyCanvasView(isFileImporterPresented: $isFileImporterPresented)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onTapGesture {
            selectedItemID = nil
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls: urls)
            return true
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.applicationBundle],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task {
                    let width = windowWidth
                    let iconSize = document.configuration.iconSize
                    let appX = round((2 * width - iconSize) / 6)
                    let centerY = round(windowHeight / 2)
                    await document.addApp(
                        from: url,
                        at: CGPoint(x: appX, y: centerY),
                        undoManager: undoManager
                    )
                }
            }
        }
        .background(canvasBackgroundColor.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("DMG preview canvas")
        .task(id: firstAppSourcePath) {
            titleBarIcon = await generateTitleBarIcon()
        }
        .task(id: panelBackdropGeneration) {
            refreshPanelBackdrop()
        }
    }

    // MARK: - Panel Backdrop (public glass preview)

    /// Fingerprint of every background-affecting input to the panel backdrop composite
    /// (base background, image layers and their loaded images, text, symbols, window
    /// size), or `nil` when no panel needs the public glass preview. Item positions are
    /// deliberately excluded so drag-moves never re-composite.
    private var panelBackdropGeneration: Int? {
        guard GlassPreview.usesPublicPath,
              document.configuration.items.contains(where: { item in
                  guard let bg = item.background else { return false }
                  return bg.enabled && bg.blurRadius > 0
              })
        else { return nil }

        var hasher = Hasher()
        hasher.combine(document.configuration.window)
        hasher.combine(document.configuration.background)
        hasher.combine(document.configuration.textLayers)
        hasher.combine(document.configuration.sfSymbolLayers)
        hasher.combine(Set(document.backgroundImages.keys))
        return hasher.finalize()
    }

    /// Re-composites the shared unblurred backdrop for the current generation. Runs
    /// only on background-affecting edits; panels re-crop and re-blur the cached image
    /// on their own.
    private func refreshPanelBackdrop() {
        guard let generation = panelBackdropGeneration else {
            panelBackdrop = nil
            return
        }
        guard panelBackdrop?.generation != generation else { return }

        let configuration = document.configuration
        guard let image = CompositeRenderer.renderPanelBackdrop(
            configuration: configuration,
            layerImages: document.backgroundImages,
            scale: 2
        ) else {
            panelBackdrop = nil
            return
        }

        panelBackdrop = CanvasBackdrop(
            image: image,
            pointSize: CGSize(
                width: configuration.window.width,
                height: configuration.window.height
            ),
            generation: generation
        )
    }

    // MARK: - Subviews

    private var canvasBackground: some View {
        Rectangle()
            .fill(canvasBackgroundColor)
            .accessibilityHidden(true)
    }

    private var canvasBackgroundColor: Color {
        prefersDarkAppearance
            ? Color(white: 0.13)
            : Color(white: 0.94)
    }

    private static let titleBarHeight: CGFloat = 32
    private static let windowCornerRadius: CGFloat = 18

    private var previewColorScheme: ColorScheme {
        prefersDarkAppearance ? .dark : .light
    }

    private var dmgWindowPreview: some View {
        ZStack(alignment: .top) {
            // Content area (below title bar)
            VStack(spacing: 0) {
                Color.clear.frame(height: Self.titleBarHeight)
                contentArea
            }

            // Title bar on top of everything (including background layers)
            titleBar
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.windowCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.windowCornerRadius)
                .strokeBorder(.tertiary, lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.windowCornerRadius))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 6)
        .environment(\.colorScheme, previewColorScheme)
    }

    private var titleBar: some View {
        ZStack {
            // Title bar follows the system appearance, not the preview toggle.
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))

            HStack(spacing: 0) {
                // Traffic lights
                HStack(spacing: 8) {
                    Circle().fill(Color(red: 1, green: 0.38, blue: 0.34))
                        .frame(width: 14, height: 14)
                    Circle().fill(Color(red: 1, green: 0.74, blue: 0.21))
                        .frame(width: 14, height: 14)
                    Circle().fill(Color(red: 0.15, green: 0.78, blue: 0.26))
                        .frame(width: 14, height: 14)
                }
                .padding(.trailing, 10)

                // Volume icon + name
                Image(nsImage: titleBarIcon ?? IconComposer.diskImageVolumeIcon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .padding(.trailing, 4)

                Text(document.configuration.volumeName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(nsColor: .windowFrameTextColor))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.leading, 9)
        }
        .frame(height: Self.titleBarHeight)
    }

    private var contentArea: some View {
        GeometryReader { geo in
            let currentZoom = geo.size.width / windowWidth

            ZStack {
                windowContentBackground

                if document.configuration.background.type == .image {
                    backgroundLayersOverlay(zoom: currentZoom)
                }

                textLayersOverlay(zoom: currentZoom)

                sfSymbolLayersOverlay(zoom: currentZoom)

                itemBackgroundsOverlay(zoom: currentZoom)

                iconsOverlay(zoom: currentZoom)

                alignmentGuidesOverlay(zoom: currentZoom, geoSize: geo.size)
            }
        }
    }

    @ViewBuilder
    private var windowContentBackground: some View {
        if document.configuration.background.type == .gradient,
           let grad = document.configuration.background.gradient {
            gradientView(for: grad)
        } else {
            Rectangle()
                .fill(windowBackgroundFill)
        }
    }

    @ViewBuilder
    private func gradientView(for grad: GradientConfiguration) -> some View {
        let swiftUIStops = grad.swiftUIStops()
        switch grad.type {
        case .linear:
            let radians = grad.angle * .pi / 180
            let startPoint = UnitPoint(
                x: 0.5 + cos(radians + .pi) * 0.5,
                y: 0.5 + sin(radians + .pi) * 0.5
            )
            let endPoint = UnitPoint(
                x: 0.5 + cos(radians) * 0.5,
                y: 0.5 + sin(radians) * 0.5
            )
            Rectangle().fill(
                LinearGradient(stops: swiftUIStops, startPoint: startPoint, endPoint: endPoint)
            )
        case .radial:
            Rectangle().fill(
                RadialGradient(
                    stops: swiftUIStops,
                    center: UnitPoint(x: grad.centerX, y: grad.centerY),
                    startRadius: grad.startRadius * windowWidth,
                    endRadius: grad.endRadius * windowWidth
                )
            )
        }
    }

    // MARK: - Background Layers

    private func backgroundLayersOverlay(zoom currentZoom: CGFloat) -> some View {
        ForEach(document.configuration.background.layers) { layer in
            if let image = document.backgroundImages[layer.id] {
                BackgroundLayerCanvasView(
                    layer: layer,
                    image: image,
                    isSelected: selectedItemID == layer.id,
                    zoom: currentZoom,
                    windowWidth: windowWidth,
                    onDragChanged: { proposed in
                        snapToGuides(proposed: proposed, excludingItemID: layer.id)
                    }
                ) { newPosition in
                    activeGuides = .none
                    document.moveBackgroundLayer(
                        layer.id,
                        to: newPosition,
                        undoManager: undoManager
                    )
                } onSelect: {
                    selectedItemID = layer.id
                }
            }
        }
    }

    // MARK: - Text Layers

    private func textLayersOverlay(zoom currentZoom: CGFloat) -> some View {
        ForEach(document.configuration.textLayers) { layer in
            TextLayerCanvasView(
                layer: layer,
                isSelected: selectedItemID == layer.id,
                zoom: currentZoom,
                onDragChanged: { proposed in
                    snapToGuides(proposed: proposed, excludingItemID: layer.id)
                }
            ) { newPosition in
                activeGuides = .none
                document.moveTextLayer(
                    layer.id,
                    to: newPosition,
                    undoManager: undoManager
                )
            } onSelect: {
                selectedItemID = layer.id
            }
        }
    }

    // MARK: - SF Symbol Layers

    private func sfSymbolLayersOverlay(zoom currentZoom: CGFloat) -> some View {
        ForEach(document.configuration.sfSymbolLayers) { layer in
            SFSymbolLayerCanvasView(
                layer: layer,
                isSelected: selectedItemID == layer.id,
                zoom: currentZoom,
                onDragChanged: { proposed in
                    snapToGuides(proposed: proposed, excludingItemID: layer.id)
                }
            ) { newPosition in
                activeGuides = .none
                document.moveSFSymbolLayer(
                    layer.id,
                    to: newPosition,
                    undoManager: undoManager
                )
            } onSelect: {
                selectedItemID = layer.id
            }
        }
    }

    // MARK: - Item Backgrounds

    private func itemBackgroundsOverlay(zoom currentZoom: CGFloat) -> some View {
        let iconSize = document.configuration.iconSize

        return ForEach(document.configuration.items.filter { item in
            guard let bg = item.background else { return false }
            return bg.enabled || bg.shadow?.enabled == true || bg.bevel?.enabled == true
        }) { item in
            ItemBackgroundPanel(
                item: item,
                bg: item.background!,
                currentZoom: currentZoom,
                iconSize: iconSize,
                backdrop: panelBackdrop
            )
        }
    }

    // MARK: - Icons

    private func iconsOverlay(zoom currentZoom: CGFloat) -> some View {
        ForEach(document.configuration.items) { item in
            CanvasItemView(
                item: item,
                isSelected: selectedItemID == item.id,
                iconSize: document.configuration.iconSize,
                textSize: document.configuration.textSize,
                zoom: currentZoom,
                windowSize: CGSize(
                    width: windowWidth,
                    height: windowHeight
                ),
                hideExtensions: document.configuration.hideExtensions,
                onDragChanged: { proposed in
                    snapToGuides(proposed: proposed, excludingItemID: item.id)
                }
            ) { newPosition in
                activeGuides = .none
                document.moveItem(item.id, to: newPosition, undoManager: undoManager)
            } onSelect: {
                selectedItemID = item.id
            }
        }
    }

    // MARK: - Alignment Guides

    private func alignmentGuidesOverlay(zoom currentZoom: CGFloat, geoSize: CGSize) -> some View {
        ZStack {
            ForEach(Array(activeGuides.verticalLines), id: \.self) { x in
                Path { path in
                    path.move(to: CGPoint(x: x * currentZoom, y: 0))
                    path.addLine(to: CGPoint(x: x * currentZoom, y: geoSize.height))
                }
                .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            ForEach(Array(activeGuides.horizontalLines), id: \.self) { y in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y * currentZoom))
                    path.addLine(to: CGPoint(x: geoSize.width, y: y * currentZoom))
                }
                .stroke(Color.accentColor.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .allowsHitTesting(false)
    }

    private static let guideSnapThreshold: CGFloat = 5

    /// Collects all positions of items other than the one being dragged.
    private func siblingPositions(excludingItemID id: UUID) -> [CGPoint] {
        var positions: [CGPoint] = []
        for item in document.configuration.items where item.id != id {
            positions.append(item.position)
        }
        for layer in document.configuration.textLayers where layer.id != id {
            positions.append(layer.position)
        }
        for layer in document.configuration.sfSymbolLayers where layer.id != id {
            positions.append(layer.position)
        }
        return positions
    }

    /// Snaps a proposed position to structural and sibling guides.
    /// Returns the snapped position (rounded to integers) and updates `activeGuides`.
    private func snapToGuides(
        proposed: CGPoint,
        excludingItemID id: UUID
    ) -> CGPoint {
        let threshold = Self.guideSnapThreshold
        var guides = AlignmentGuides()
        var snappedX = proposed.x
        var snappedY = proposed.y

        // Structural guides
        let structuralVertical: [CGFloat] = [
            windowWidth / 2,
            windowWidth / 3,
            windowWidth * 2 / 3,
        ]
        let structuralHorizontal: [CGFloat] = [
            windowHeight / 2,
        ]

        for guide in structuralVertical {
            if abs(proposed.x - guide) <= threshold {
                snappedX = guide
                guides.verticalLines.insert(guide)
                break
            }
        }

        for guide in structuralHorizontal {
            if abs(proposed.y - guide) <= threshold {
                snappedY = guide
                guides.horizontalLines.insert(guide)
                break
            }
        }

        // Sibling guides
        let siblings = siblingPositions(excludingItemID: id)
        for sibling in siblings {
            if guides.verticalLines.isEmpty, abs(proposed.x - sibling.x) <= threshold {
                snappedX = sibling.x
                guides.verticalLines.insert(sibling.x)
            }
            if guides.horizontalLines.isEmpty, abs(proposed.y - sibling.y) <= threshold {
                snappedY = sibling.y
                guides.horizontalLines.insert(sibling.y)
            }
        }

        // Clamp within window bounds, round to integers
        snappedX = round(min(max(snappedX, 0), windowWidth))
        snappedY = round(min(max(snappedY, 0), windowHeight))

        activeGuides = guides
        return CGPoint(x: snappedX, y: snappedY)
    }

    // MARK: - Title Bar Icon

    private var firstAppSourcePath: String? {
        document.configuration.items.first { $0.kind == .app }?.sourcePath
    }

    private func generateTitleBarIcon() async -> NSImage? {
        guard let app = document.configuration.items.first(where: { $0.kind == .app }) else {
            return nil
        }
        return await SourceAccess.withScope(item: app, documentURL: document.fileURL) { url in
            guard let url,
                  let iconURL = IconComposer.resolveAppIconURL(appPath: url.path),
                  let icnsData = try? await IconComposer.compose(appIconURL: iconURL)
            else { return nil }
            return NSImage(data: icnsData)
        }
    }

    // MARK: - Computed

    private var windowWidth: CGFloat {
        document.configuration.window.width
    }

    private var windowHeight: CGFloat {
        document.configuration.window.height
    }

    private var windowBackgroundFill: Color {
        switch document.configuration.background.type {
        case .none, .image, .gradient:
            return Color.white
        case .color:
            let c = document.configuration.background.color
            return Color(red: c.red, green: c.green, blue: c.blue)
        }
    }

    private func effectiveZoom(fitZoom: CGFloat) -> CGFloat {
        isFitToWindow ? fitZoom : zoom
    }

    private func fitToWindowZoom(viewSize: CGSize) -> CGFloat {
        let padding: CGFloat = 80
        let availableWidth = viewSize.width - padding
        let availableHeight = viewSize.height - padding
        let totalHeight = windowHeight + Self.titleBarHeight

        guard windowWidth > 0, totalHeight > 0 else { return 1.0 }

        let scaleX = availableWidth / windowWidth
        let scaleY = availableHeight / totalHeight
        return min(scaleX, scaleY, 2.0)
    }

    // MARK: - Drop / Import

    private func handleDrop(urls: [URL]) {
        Task {
            await document.handleDrop(
                urls: urls,
                defaultPosition: CGPoint(x: windowWidth / 2, y: windowHeight / 2),
                undoManager: undoManager
            )
        }
    }
}
