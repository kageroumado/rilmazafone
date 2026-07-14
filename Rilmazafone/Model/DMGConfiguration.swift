import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Document Root

nonisolated struct DMGConfiguration: Codable, Hashable, Sendable {
    let version: Int = 1
    var volumeName: String = "Untitled"
    var window: WindowConfiguration = .init()
    var iconSize: CGFloat = 160
    var textSize: CGFloat = 13
    var gridSpacing: CGFloat = 100
    var isGridSpacingAuto: Bool = true
    var hideExtensions: Bool = true
    var background: BackgroundConfiguration = .init()
    var textLayers: [TextLayerConfiguration] = []
    var sfSymbolLayers: [SFSymbolLayerConfiguration] = []
    var items: [CanvasItem] = []
    var volumeIcon: VolumeIconConfiguration = .init()
    var codeSign: CodeSignConfiguration = .init()
    var dmgFormat: DMGImageFormat = .ulfo
    var filesystem: DMGFilesystem = .apfs
    var windowPosition: WindowPosition = .init()
    
    var effectiveGridSpacing: CGFloat {
        let raw = isGridSpacingAuto ? round(window.width / 6) : gridSpacing
        return min(raw, 100)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case volumeName
        case window
        case iconSize
        case textSize
        case gridSpacing
        case isGridSpacingAuto
        case hideExtensions
        case background
        case textLayers
        case sfSymbolLayers
        case items
        case volumeIcon
        case codeSign
        case dmgFormat
        case filesystem
        case windowPosition
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.volumeName = try container.decodeIfPresent(String.self, forKey: .volumeName) ?? "Untitled"
        self.window = try container.decodeIfPresent(WindowConfiguration.self, forKey: .window) ?? .init()
        self.iconSize = try container.decodeIfPresent(CGFloat.self, forKey: .iconSize) ?? 160
        self.textSize = try container.decodeIfPresent(CGFloat.self, forKey: .textSize) ?? 13
        self.gridSpacing = try container.decodeIfPresent(CGFloat.self, forKey: .gridSpacing) ?? 100
        self.isGridSpacingAuto = try container.decodeIfPresent(Bool.self, forKey: .isGridSpacingAuto) ?? true
        self.hideExtensions = try container.decodeIfPresent(Bool.self, forKey: .hideExtensions) ?? true
        self.background = try container.decodeIfPresent(BackgroundConfiguration.self, forKey: .background) ?? .init()
        self.textLayers = try container.decodeIfPresent([TextLayerConfiguration].self, forKey: .textLayers) ?? []
        self.sfSymbolLayers = try container.decodeIfPresent([SFSymbolLayerConfiguration].self, forKey: .sfSymbolLayers) ?? []
        self.items = try container.decodeIfPresent([CanvasItem].self, forKey: .items) ?? []
        self.volumeIcon = try container.decodeIfPresent(VolumeIconConfiguration.self, forKey: .volumeIcon) ?? .init()
        self.codeSign = try container.decodeIfPresent(CodeSignConfiguration.self, forKey: .codeSign) ?? .init()
        self.dmgFormat = try container.decodeIfPresent(DMGImageFormat.self, forKey: .dmgFormat) ?? .ulfo
        self.filesystem = try container.decodeIfPresent(DMGFilesystem.self, forKey: .filesystem) ?? .apfs
        self.windowPosition = try container.decodeIfPresent(WindowPosition.self, forKey: .windowPosition) ?? .init()
    }
}

// MARK: - Path Portability

nonisolated extension DMGConfiguration {
    private static let homeDirectory = FileManager.default
        .homeDirectoryForCurrentUser.path

    /// Replaces absolute home directory paths with `~` for portable storage.
    mutating func abbreviatePaths() {
        let home = Self.homeDirectory
        for i in items.indices {
            if let path = items[i].sourcePath, path.hasPrefix(home) {
                items[i].sourcePath = "~" + path.dropFirst(home.count)
            }
        }
    }

    /// Expands `~` prefixed paths to the current user's home directory.
    mutating func expandAbbreviatedPaths() {
        let home = Self.homeDirectory
        for i in items.indices {
            if let path = items[i].sourcePath, path.hasPrefix("~/") {
                items[i].sourcePath = home + String(path.dropFirst(1))
            }
        }
    }
}

// MARK: - Window

nonisolated struct WindowConfiguration: Codable, Hashable, Sendable {
    var width: CGFloat = 660
    var height: CGFloat = 400
}

// MARK: - Background

nonisolated struct BackgroundConfiguration: Codable, Hashable, Sendable {
    var type: BackgroundType = .none
    var color: RGBColor = .init(red: 0.92, green: 0.92, blue: 0.92)
    var gradient: GradientConfiguration?
    var layers: [BackgroundLayer] = []

    private enum CodingKeys: String, CodingKey {
        case type
        case color
        case gradient
        case layers
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(BackgroundType.self, forKey: .type) ?? .none
        self.color = try container.decodeIfPresent(RGBColor.self, forKey: .color) ?? RGBColor(red: 0.92, green: 0.92, blue: 0.92)
        self.gradient = try container.decodeIfPresent(GradientConfiguration.self, forKey: .gradient)
        self.layers = try container.decodeIfPresent([BackgroundLayer].self, forKey: .layers) ?? []
    }
}

nonisolated enum BackgroundType: String, Codable, CaseIterable, Sendable {
    case none
    case color
    case gradient
    case image
}

nonisolated struct BackgroundLayer: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var imageName: String
    var label: String
    var position: CGPoint = .init(x: 330, y: 200)
    var scale: CGFloat = 1.0
    var blurRadius: CGFloat = 0
    var variableBlur: VariableBlurConfiguration?
    var colorAdjustments: ColorAdjustments?
    var vignette: VignetteConfiguration?
    var bloom: BloomConfiguration?

    init(id: UUID = UUID(), imageName: String, label: String, position: CGPoint = CGPoint(x: 330, y: 200), scale: CGFloat = 1.0, blurRadius: CGFloat = 0) {
        self.id = id
        self.imageName = imageName
        self.label = label
        self.position = position
        self.scale = scale
        self.blurRadius = blurRadius
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.imageName = try container.decode(String.self, forKey: .imageName)
        self.label = try container.decode(String.self, forKey: .label)
        self.position = try container.decodeIfPresent(CGPoint.self, forKey: .position) ?? CGPoint(x: 330, y: 200)
        self.scale = try container.decodeIfPresent(CGFloat.self, forKey: .scale) ?? 1.0
        self.blurRadius = try container.decodeIfPresent(CGFloat.self, forKey: .blurRadius) ?? 0
        self.variableBlur = try container.decodeIfPresent(VariableBlurConfiguration.self, forKey: .variableBlur)
        self.colorAdjustments = try container.decodeIfPresent(ColorAdjustments.self, forKey: .colorAdjustments)
        self.vignette = try container.decodeIfPresent(VignetteConfiguration.self, forKey: .vignette)
        self.bloom = try container.decodeIfPresent(BloomConfiguration.self, forKey: .bloom)
    }
}

nonisolated struct RGBColor: Codable, Hashable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
}

// MARK: - RGBColor + SwiftUI

extension RGBColor {
    var swiftUIColor: Color {
        Color(nsColor: NSColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    }

    init?(swiftUIColor: Color) {
        guard let srgb = NSColor(swiftUIColor).usingColorSpace(.sRGB) else { return nil }
        self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }
}

// MARK: - Gradient

nonisolated struct GradientConfiguration: Codable, Hashable, Sendable {
    var type: GradientType = .linear
    var stops: [GradientStop] = [
        GradientStop(color: RGBColor(red: 0.3, green: 0.5, blue: 0.9), location: 0),
        GradientStop(color: RGBColor(red: 0.9, green: 0.4, blue: 0.6), location: 1),
    ]
    var angle: CGFloat = 180
    var centerX: CGFloat = 0.5
    var centerY: CGFloat = 0.5
    var startRadius: CGFloat = 0
    var endRadius: CGFloat = 0.5

    private enum CodingKeys: String, CodingKey {
        case type
        case stops
        case angle
        case centerX
        case centerY
        case startRadius
        case endRadius
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(GradientType.self, forKey: .type) ?? .linear
        self.stops = try container.decodeIfPresent([GradientStop].self, forKey: .stops) ?? [
            GradientStop(color: RGBColor(red: 0.3, green: 0.5, blue: 0.9), location: 0),
            GradientStop(color: RGBColor(red: 0.9, green: 0.4, blue: 0.6), location: 1),
        ]
        self.angle = try container.decodeIfPresent(CGFloat.self, forKey: .angle) ?? 180
        self.centerX = try container.decodeIfPresent(CGFloat.self, forKey: .centerX) ?? 0.5
        self.centerY = try container.decodeIfPresent(CGFloat.self, forKey: .centerY) ?? 0.5
        self.startRadius = try container.decodeIfPresent(CGFloat.self, forKey: .startRadius) ?? 0
        self.endRadius = try container.decodeIfPresent(CGFloat.self, forKey: .endRadius) ?? 0.5
    }
}

nonisolated enum GradientType: String, Codable, CaseIterable, Sendable {
    case linear
    case radial
}

nonisolated struct GradientStop: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = .init()
    var color: RGBColor
    var location: CGFloat
}

extension GradientConfiguration {
    func swiftUIStops() -> [Gradient.Stop] {
        stops.sorted { $0.location < $1.location }.map { stop in
            Gradient.Stop(
                color: Color(red: stop.color.red, green: stop.color.green, blue: stop.color.blue),
                location: stop.location
            )
        }
    }
}

// MARK: - Variable Blur

nonisolated struct VariableBlurConfiguration: Codable, Hashable, Sendable {
    var radius: CGFloat = 20
    var maskType: VariableBlurMaskType = .linear
    var angle: CGFloat = 180
    var centerX: CGFloat = 0.5
    var centerY: CGFloat = 0.5
    var startPoint: CGFloat = 0.3
    var endPoint: CGFloat = 0.7
}

nonisolated enum VariableBlurMaskType: String, Codable, CaseIterable, Sendable {
    case linear
    case radial
}

// MARK: - Color Adjustments

nonisolated struct ColorAdjustments: Codable, Hashable, Sendable {
    var brightness: CGFloat = 0
    var contrast: CGFloat = 1
    var saturation: CGFloat = 1
    var hueRotation: CGFloat = 0
    var exposure: CGFloat = 0
}

// MARK: - Vignette

nonisolated struct VignetteConfiguration: Codable, Hashable, Sendable {
    var intensity: CGFloat = 0.8
    var radius: CGFloat = 1.0
}

// MARK: - Bloom

nonisolated struct BloomConfiguration: Codable, Hashable, Sendable {
    var intensity: CGFloat = 0.5
    var radius: CGFloat = 10
}

// MARK: - Shadow

nonisolated struct ShadowConfiguration: Codable, Hashable, Sendable {
    var enabled: Bool = true
    var color: RGBColor = .init(red: 0, green: 0, blue: 0)
    var opacity: CGFloat = 0.5
    var radius: CGFloat = 8
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 4

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.color = try container.decodeIfPresent(RGBColor.self, forKey: .color)
            ?? RGBColor(red: 0, green: 0, blue: 0)
        self.opacity = try container.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 0.5
        self.radius = try container.decodeIfPresent(CGFloat.self, forKey: .radius) ?? 8
        self.offsetX = try container.decodeIfPresent(CGFloat.self, forKey: .offsetX) ?? 0
        self.offsetY = try container.decodeIfPresent(CGFloat.self, forKey: .offsetY) ?? 4
    }
}

// MARK: - Bevel

nonisolated struct BevelConfiguration: Codable, Hashable, Sendable {
    var enabled: Bool = true
    var depth: CGFloat = 5
    var lightAngle: CGFloat = 135
    var intensity: CGFloat = 0.5

    init(
        enabled: Bool = true,
        depth: CGFloat = 5,
        lightAngle: CGFloat = 135,
        intensity: CGFloat = 0.5
    ) {
        self.enabled = enabled
        self.depth = depth
        self.lightAngle = lightAngle
        self.intensity = intensity
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.depth = try container.decodeIfPresent(CGFloat.self, forKey: .depth) ?? 5
        self.lightAngle = try container.decodeIfPresent(CGFloat.self, forKey: .lightAngle) ?? 135
        self.intensity = try container.decodeIfPresent(CGFloat.self, forKey: .intensity) ?? 0.5
    }
}

// MARK: - Text Layers

nonisolated struct TextLayerConfiguration: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = .init()
    var text: String = "Text"
    var position: CGPoint
    var fontFamily: String = "Helvetica Neue"
    var fontSize: CGFloat = 24
    var isBold: Bool = false
    var isItalic: Bool = false
    var color: RGBColor = .init(red: 0, green: 0, blue: 0)
}

// MARK: - SF Symbol Layers

nonisolated struct SFSymbolLayerConfiguration: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = .init()
    var position: CGPoint
    var symbolName: String = "arrow.right"
    var pointSize: CGFloat = 48
    var weight: SFSymbolWeight = .regular
    var color: RGBColor = .init(red: 0, green: 0, blue: 0)
}

nonisolated enum SFSymbolWeight: String, Codable, CaseIterable, Sendable {
    case ultraLight
    case thin
    case light
    case regular
    case medium
    case semibold
    case bold
    case heavy
    case black

    var nsFontWeight: NSFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        }
    }
}

// MARK: - Canvas Items

nonisolated struct CanvasItem: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = .init()
    var kind: CanvasItemKind
    var label: String
    var sourcePath: String?
    /// Security-scoped bookmark to the source, used by the sandboxed App Store
    /// build to regain access across launches. The GitHub build never creates
    /// one but round-trips the data losslessly.
    var sourceBookmark: Data?
    /// Name of an embedded payload in the containing package's `Assets`
    /// directory. When set, the item's content lives inside the document or
    /// template itself (files verbatim, folders as Apple Archives — see
    /// ``EmbeddedAssets``) and `sourcePath`/`sourceBookmark` are nil: the item
    /// is fully portable and never needs relinking.
    var assetName: String?
    var position: CGPoint
    var linkType: ItemLinkType = .copy
    var background: ItemBackground?
    /// Whether this item is an unfilled placeholder slot awaiting a dropped
    /// source of its own kind — an app, a folder, or a file. Placeholders render
    /// as a dashed tile with a kind-appropriate glyph, carry no source, and block
    /// builds until filled. Templates and DMG import seed items in this state;
    /// ``RilmazafoneDocument/fillPlaceholder(_:from:undoManager:)`` clears it in place.
    var isPlaceholder: Bool = false

    init(id: UUID = UUID(), kind: CanvasItemKind, label: String, sourcePath: String? = nil, sourceBookmark: Data? = nil, assetName: String? = nil, position: CGPoint, linkType: ItemLinkType = .copy, background: ItemBackground? = nil, isPlaceholder: Bool = false) {
        self.id = id
        self.kind = kind
        self.label = label
        self.sourcePath = sourcePath
        self.sourceBookmark = sourceBookmark
        self.assetName = assetName
        self.position = position
        self.linkType = linkType
        self.background = background
        self.isPlaceholder = isPlaceholder
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.kind = try container.decode(CanvasItemKind.self, forKey: .kind)
        self.label = try container.decode(String.self, forKey: .label)
        self.sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
        self.sourceBookmark = try container.decodeIfPresent(Data.self, forKey: .sourceBookmark)
        self.assetName = try container.decodeIfPresent(String.self, forKey: .assetName)
        self.position = try container.decode(CGPoint.self, forKey: .position)
        self.linkType = try container.decodeIfPresent(ItemLinkType.self, forKey: .linkType) ?? .copy
        self.background = try container.decodeIfPresent(ItemBackground.self, forKey: .background)
        self.isPlaceholder = try container.decodeIfPresent(Bool.self, forKey: .isPlaceholder) ?? false
    }

    /// Default label for a fresh app placeholder slot.
    static let placeholderLabel = "Your App"

    /// Default label for a fresh folder placeholder slot.
    static let folderPlaceholderLabel = "Documentation"

    /// Default label for a fresh file placeholder slot.
    static let filePlaceholderLabel = "Read Me"

    /// Creates an unfilled app placeholder slot at the given position.
    static func appPlaceholder(
        label: String = placeholderLabel,
        position: CGPoint
    ) -> CanvasItem {
        CanvasItem(kind: .app, label: label, position: position, isPlaceholder: true)
    }

    /// Creates an unfilled folder placeholder slot at the given position — the
    /// slot a dropped folder (e.g. bundled documentation) fills.
    static func folderPlaceholder(
        label: String = folderPlaceholderLabel,
        position: CGPoint
    ) -> CanvasItem {
        CanvasItem(kind: .folder, label: label, position: position, isPlaceholder: true)
    }

    /// Creates an unfilled file placeholder slot at the given position — the
    /// slot a dropped file (e.g. a Read Me) fills.
    static func filePlaceholder(
        label: String = filePlaceholderLabel,
        position: CGPoint
    ) -> CanvasItem {
        CanvasItem(kind: .file, label: label, position: position, isPlaceholder: true)
    }

    /// SF Symbol name for the dashed placeholder tile of each kind. The
    /// Applications symlink is never a placeholder, so it falls back to the app
    /// glyph defensively.
    var placeholderGlyphName: String {
        switch kind {
        case .app, .applicationsSymlink: "app.dashed"
        case .folder: "folder"
        case .file: "doc"
        }
    }

    /// Whether this item carries its content inside the containing package
    /// rather than referencing an external source.
    var isEmbedded: Bool { assetName != nil }

    /// Whether this item copies a filesystem source into the DMG and therefore
    /// needs a reachable source. The Applications symlink and symlink-type items
    /// only store a target path string; an unfilled placeholder has no source
    /// yet and is validated separately; an embedded item's content lives inside
    /// the package and is materialized at build time — all excluded here,
    /// keeping them out of the missing-source machinery (badge, relink,
    /// `missingSources`).
    var requiresSource: Bool {
        kind != .applicationsSymlink && linkType == .copy && !isPlaceholder && !isEmbedded
    }
}

// MARK: - Item Background

nonisolated struct ItemBackground: Codable, Hashable, Sendable {
    var enabled: Bool = true
    var color: RGBColor = .init(red: 1, green: 1, blue: 1)
    var opacity: CGFloat = 0.3
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 20
    var blurRadius: CGFloat = 20
    var blurFeather: CGFloat = 0
    var blendMode: ItemBlendMode = .normal
    var shadow: ShadowConfiguration?
    var bevel: BevelConfiguration?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case color
        case opacity
        case cornerRadius
        case padding
        case blurRadius
        case blurFeather
        case blendMode
        case shadow
        case bevel
    }

    init(
        enabled: Bool = true,
        color: RGBColor = RGBColor(red: 1, green: 1, blue: 1),
        opacity: CGFloat = 0.3,
        cornerRadius: CGFloat = 16,
        padding: CGFloat = 20,
        blurRadius: CGFloat = 20,
        blurFeather: CGFloat = 0,
        blendMode: ItemBlendMode = .normal,
        shadow: ShadowConfiguration? = nil,
        bevel: BevelConfiguration? = nil
    ) {
        self.enabled = enabled
        self.color = color
        self.opacity = opacity
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.blurRadius = blurRadius
        self.blurFeather = blurFeather
        self.blendMode = blendMode
        self.shadow = shadow
        self.bevel = bevel
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.color = try container.decodeIfPresent(RGBColor.self, forKey: .color) ?? RGBColor(red: 1, green: 1, blue: 1)
        self.opacity = try container.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 0.3
        self.cornerRadius = try container.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 16
        self.padding = try container.decodeIfPresent(CGFloat.self, forKey: .padding) ?? 20
        self.blurRadius = try container.decodeIfPresent(CGFloat.self, forKey: .blurRadius) ?? 20
        self.blurFeather = try container.decodeIfPresent(CGFloat.self, forKey: .blurFeather) ?? 0
        self.blendMode = try container.decodeIfPresent(ItemBlendMode.self, forKey: .blendMode) ?? .normal
        self.shadow = try container.decodeIfPresent(ShadowConfiguration.self, forKey: .shadow)
        self.bevel = try container.decodeIfPresent(BevelConfiguration.self, forKey: .bevel)
    }
}

nonisolated enum ItemBlendMode: String, Codable, CaseIterable, Sendable {
    case normal
    case overlay
    case softLight
    case multiply
    case screen
    case colorBurn
    case colorDodge
    case lighten
    case darken

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .multiply: "Multiply"
        case .screen: "Screen"
        case .colorBurn: "Color Burn"
        case .colorDodge: "Color Dodge"
        case .lighten: "Lighten"
        case .darken: "Darken"
        }
    }

    var swiftUIBlendMode: SwiftUI.BlendMode {
        switch self {
        case .normal: .normal
        case .overlay: .overlay
        case .softLight: .softLight
        case .multiply: .multiply
        case .screen: .screen
        case .colorBurn: .colorBurn
        case .colorDodge: .colorDodge
        case .lighten: .lighten
        case .darken: .darken
        }
    }

    var cgBlendMode: CGBlendMode {
        switch self {
        case .normal: .normal
        case .overlay: .overlay
        case .softLight: .softLight
        case .multiply: .multiply
        case .screen: .screen
        case .colorBurn: .colorBurn
        case .colorDodge: .colorDodge
        case .lighten: .lighten
        case .darken: .darken
        }
    }
}

nonisolated enum ItemLinkType: String, Codable, CaseIterable, Sendable {
    case copy
    case symlink
}

nonisolated enum CanvasItemKind: String, Codable, CaseIterable, Sendable {
    case app
    case applicationsSymlink
    case file
    case folder
}

// MARK: - Icon Resolution

extension CanvasItem {
    /// Icon for the Applications symlink, fetched once via a temporary symlink
    /// so IconServices renders the correct alias badge.
    static let applicationsSymlinkIcon: NSImage = {
        let tempDir = FileManager.default.temporaryDirectory
        let tempLink = tempDir.appending(path: "RilmazafoneAppLink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempLink) }
        try? FileManager.default.createSymbolicLink(
            at: tempLink,
            withDestinationURL: URL(filePath: "/Applications")
        )
        return NSWorkspace.shared.icon(forFile: tempLink.path)
    }()

    /// Resolves the filesystem icon for a canvas item.
    /// For apps/files/folders, returns the icon from the source path, holding
    /// security-scoped access to the source in the sandboxed build. Embedded
    /// items have no filesystem presence until build time, so their icon comes
    /// from the item's kind and the label's extension.
    /// For the Applications symlink, returns the cached symlink icon.
    static func resolveIcon(for item: CanvasItem, documentURL: URL? = nil) -> NSImage? {
        switch item.kind {
        case .applicationsSymlink:
            return applicationsSymlinkIcon
        case .app, .file, .folder:
            if item.isEmbedded {
                return embeddedTypeIcon(for: item)
            }
            return SourceAccess.withScope(item: item, documentURL: documentURL) { url in
                guard let url,
                      FileManager.default.fileExists(atPath: url.path) else { return nil }
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
    }

    /// Kind- and extension-derived icon for an embedded item.
    private static func embeddedTypeIcon(for item: CanvasItem) -> NSImage {
        if item.kind == .folder {
            return NSWorkspace.shared.icon(for: .folder)
        }
        let fileExtension = (item.label as NSString).pathExtension
        let type = UTType(filenameExtension: fileExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }

    /// Equatable key views use with `.task(id:)` to reload a cached source icon
    /// when the item's source reference or its availability changes.
    struct IconCacheKey: Equatable {
        let sourcePath: String?
        let sourceBookmark: Data?
        let assetName: String?
        let isSourceMissing: Bool
    }

    /// The icon-reload key for this item given its current availability state.
    func iconCacheKey(isSourceMissing: Bool) -> IconCacheKey {
        IconCacheKey(
            sourcePath: sourcePath,
            sourceBookmark: sourceBookmark,
            assetName: assetName,
            isSourceMissing: isSourceMissing
        )
    }
}

// MARK: - Volume Icon

nonisolated struct VolumeIconConfiguration: Codable, Hashable, Sendable {
    var type: VolumeIconType = .composed
    var sourceIconName: String?
}

nonisolated enum VolumeIconType: String, Codable, CaseIterable, Sendable {
    case composed
    case custom
    case none
}

// MARK: - Code Signing

nonisolated struct CodeSignConfiguration: Codable, Hashable, Sendable {
    var enabled: Bool = false
    var identity: String?
}

// MARK: - DMG Image Format

nonisolated enum DMGImageFormat: String, Codable, CaseIterable, Sendable {
    case udzo = "UDZO" // zlib compressed (most compatible)
    case udbz = "UDBZ" // bzip2 compressed (smaller, slower)
    case ulfo = "ULFO" // LZFSE compressed (fast, macOS 10.11+)
    case ulmo = "ULMO" // lzma compressed (smallest, slowest)

    var displayName: String {
        switch self {
        case .udzo: "zlib (UDZO)"
        case .udbz: "bzip2 (UDBZ)"
        case .ulfo: "LZFSE (ULFO)"
        case .ulmo: "lzma (ULMO)"
        }
    }
}

// MARK: - DMG Filesystem

nonisolated enum DMGFilesystem: String, Codable, CaseIterable, Sendable {
    case hfsPlus = "HFS+"
    case apfs = "APFS"

    var displayName: String {
        switch self {
        case .hfsPlus: "HFS+"
        case .apfs: "APFS"
        }
    }
}

// MARK: - Window Position

nonisolated struct WindowPosition: Codable, Hashable, Sendable {
    var x: Int = 200
    var y: Int = 120
}
