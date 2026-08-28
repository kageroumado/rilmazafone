import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Document Root

nonisolated struct DMGConfiguration: Codable, Hashable {
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
    
    /// Whether the DMG needs a composite background image written to the volume.
    ///
    /// A flat color is the only background Finder can draw from the `.DS_Store` alone;
    /// everything else — a ramp, a mesh, image layers, type, symbols, item panels, grain
    /// — has to be baked into a picture. Every surface that decides whether to render one
    /// asks here, so a new effect cannot be added and then silently left out of a build.
    var needsCompositeBackground: Bool {
        if !textLayers.isEmpty || !sfSymbolLayers.isEmpty {
            return true
        }
        if items.contains(where: { $0.background?.draws == true }) {
            return true
        }
        if background.grain?.enabled == true {
            return true
        }

        switch background.type {
        case .none, .color: return false
        case .gradient: return background.gradient != nil
        case .mesh: return background.mesh != nil
        case .image: return !background.layers.isEmpty
        }
    }

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

nonisolated struct WindowConfiguration: Codable, Hashable {
    var width: CGFloat = 660
    var height: CGFloat = 400
}

// MARK: - Background

nonisolated struct BackgroundConfiguration: Codable, Hashable {
    var type: BackgroundType = .none
    var color: RGBColor = .init(red: 0.92, green: 0.92, blue: 0.92)
    var gradient: GradientConfiguration?
    var mesh: MeshGradientConfiguration?
    var layers: [BackgroundLayer] = []
    var grain: GrainConfiguration?

    private enum CodingKeys: String, CodingKey {
        case type
        case color
        case gradient
        case mesh
        case layers
        case grain
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try container.decodeIfPresent(BackgroundType.self, forKey: .type) ?? .none
        self.color = try container.decodeIfPresent(RGBColor.self, forKey: .color) ?? RGBColor(red: 0.92, green: 0.92, blue: 0.92)
        self.gradient = try container.decodeIfPresent(GradientConfiguration.self, forKey: .gradient)
        self.mesh = try container.decodeIfPresent(MeshGradientConfiguration.self, forKey: .mesh)
        self.layers = try container.decodeIfPresent([BackgroundLayer].self, forKey: .layers) ?? []
        self.grain = try container.decodeIfPresent(GrainConfiguration.self, forKey: .grain)
    }
}

nonisolated enum BackgroundType: String, Codable, CaseIterable {
    case none
    case color
    case gradient
    case mesh
    case image

    var displayName: String {
        switch self {
        case .none: "None"
        case .color: "Color"
        case .gradient: "Gradient"
        case .mesh: "Mesh"
        case .image: "Image"
        }
    }
}

// MARK: - Grain

/// A speckle laid over the finished background.
///
/// At small amounts it is a dither: an 8-bit gradient across a window this size bands
/// visibly, and the disk image is compressed losslessly, so nothing downstream hides it.
/// A per-pixel perturbation smaller than one step breaks the banding up. Turned up, the
/// same mechanism reads as film grain.
nonisolated struct GrainConfiguration: Codable, Hashable {
    var enabled: Bool = true
    /// How far a grain sample can push a pixel, 0...1. Around 0.02 dithers; 0.1 and up
    /// reads as texture.
    var amount: CGFloat = 0.02
    /// Grain cell size in points. 1 is per-pixel; larger values read as coarser film.
    var size: CGFloat = 1
    /// Whether grain moves the channels independently rather than all three together.
    var isColored: Bool = false

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.amount = try container.decodeIfPresent(CGFloat.self, forKey: .amount) ?? 0.02
        self.size = try container.decodeIfPresent(CGFloat.self, forKey: .size) ?? 1
        self.isColored = try container.decodeIfPresent(Bool.self, forKey: .isColored) ?? false
    }
}

// MARK: - Mesh Gradient

/// A grid of colored control points the background is interpolated between — the look a
/// linear or radial ramp cannot reach, because color varies in two directions at once.
nonisolated struct MeshGradientConfiguration: Codable, Hashable {
    var columns: Int = 3
    var rows: Int = 3
    /// Control points in row-major order, `columns * rows` of them.
    var points: [MeshControlPoint] = MeshGradientConfiguration.defaultPoints
    /// Whether to interpolate with a smoothstep ramp rather than linearly, which hides
    /// the seams between patches.
    var smoothsColors: Bool = true

    /// A three-by-three grid on an even lattice, running violet through pink to amber.
    static let defaultPoints: [MeshControlPoint] = [
        .init(color: .init(red: 0.24, green: 0.11, blue: 0.44)),
        .init(color: .init(red: 0.42, green: 0.16, blue: 0.60)),
        .init(color: .init(red: 0.62, green: 0.22, blue: 0.62)),
        .init(color: .init(red: 0.44, green: 0.20, blue: 0.66)),
        .init(color: .init(red: 0.79, green: 0.35, blue: 0.62)),
        .init(color: .init(red: 0.95, green: 0.48, blue: 0.52)),
        .init(color: .init(red: 0.70, green: 0.30, blue: 0.60)),
        .init(color: .init(red: 0.96, green: 0.55, blue: 0.45)),
        .init(color: .init(red: 0.99, green: 0.76, blue: 0.44)),
    ]

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.columns = try container.decodeIfPresent(Int.self, forKey: .columns) ?? 3
        self.rows = try container.decodeIfPresent(Int.self, forKey: .rows) ?? 3
        self.points = try container.decodeIfPresent([MeshControlPoint].self, forKey: .points)
            ?? MeshGradientConfiguration.defaultPoints
        self.smoothsColors = try container.decodeIfPresent(Bool.self, forKey: .smoothsColors) ?? true
    }

    /// The control point at a grid position, or `nil` when `points` is the wrong length
    /// for `columns` × `rows`.
    func point(column: Int, row: Int) -> MeshControlPoint? {
        let index = row * columns + column
        guard points.indices.contains(index) else { return nil }
        return points[index]
    }

    /// Whether the grid is large enough and fully populated to be drawn.
    var isDrawable: Bool {
        columns >= 2 && rows >= 2 && points.count >= columns * rows
    }

    /// The mesh's color at parameter (`u`, `v`) in the unit square, where (0, 0) is the
    /// window's top-left corner.
    ///
    /// The inspector previews through this and resizing the grid re-samples through it,
    /// so the mesh has one definition of what it looks like. The renderer inlines the
    /// same arithmetic across whole rows, which is the only reason it does not call here.
    func color(u: CGFloat, v: CGFloat) -> RGBColor? {
        guard isDrawable else { return nil }

        let scaledU = min(max(u, 0), 1) * CGFloat(columns - 1)
        let scaledV = min(max(v, 0), 1) * CGFloat(rows - 1)
        let cellColumn = min(Int(scaledU), columns - 2)
        let cellRow = min(Int(scaledV), rows - 2)

        guard let topLeft = point(column: cellColumn, row: cellRow),
              let topRight = point(column: cellColumn + 1, row: cellRow),
              let bottomLeft = point(column: cellColumn, row: cellRow + 1),
              let bottomRight = point(column: cellColumn + 1, row: cellRow + 1)
        else { return nil }

        let weightU = Self.weight(scaledU - CGFloat(cellColumn), smoothed: smoothsColors)
        let weightV = Self.weight(scaledV - CGFloat(cellRow), smoothed: smoothsColors)

        func channel(_ component: (RGBColor) -> CGFloat) -> CGFloat {
            let top = Self.lerp(component(topLeft.color), component(topRight.color), weightU)
            let bottom = Self.lerp(component(bottomLeft.color), component(bottomRight.color), weightU)
            return Self.lerp(top, bottom, weightV)
        }

        return RGBColor(red: channel(\.red), green: channel(\.green), blue: channel(\.blue))
    }

    /// The same mesh on a grid of a different size, re-sampled so the look survives the
    /// resize instead of resetting to the default palette.
    func resized(columns newColumns: Int, rows newRows: Int) -> MeshGradientConfiguration {
        let clampedColumns = min(max(newColumns, 2), 8)
        let clampedRows = min(max(newRows, 2), 8)

        var resized = self
        resized.columns = clampedColumns
        resized.rows = clampedRows
        resized.points = (0 ..< clampedRows).flatMap { row in
            (0 ..< clampedColumns).map { column in
                MeshControlPoint(color: color(
                    u: CGFloat(column) / CGFloat(clampedColumns - 1),
                    v: CGFloat(row) / CGFloat(clampedRows - 1),
                ) ?? RGBColor(red: 0.5, green: 0.5, blue: 0.5))
            }
        }
        return resized
    }

    /// The interpolation weight for a position across one patch. A smoothstep ramp is
    /// what hides the seams where patches meet.
    static func weight(_ t: CGFloat, smoothed: Bool) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return smoothed ? clamped * clamped * (3 - 2 * clamped) : clamped
    }

    static func lerp(_ from: CGFloat, _ to: CGFloat, _ t: CGFloat) -> CGFloat {
        from + (to - from) * t
    }
}

/// One node of the mesh. Nodes sit on an even lattice: the grid is the geometry, and
/// what an author sets is the color at each intersection.
nonisolated struct MeshControlPoint: Codable, Hashable, Identifiable {
    var id: UUID = .init()
    var color: RGBColor
}

nonisolated struct BackgroundLayer: Codable, Hashable, Identifiable {
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
    var gradientMap: GradientMapConfiguration?

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
        self.gradientMap = try container.decodeIfPresent(GradientMapConfiguration.self, forKey: .gradientMap)
    }
}

// MARK: - Gradient Map

/// Re-colors an image by its own brightness: the darkest pixels take the first stop, the
/// brightest the last. One control turns a photograph into a two- or three-tone image in
/// the document's palette.
nonisolated struct GradientMapConfiguration: Codable, Hashable {
    var enabled: Bool = true
    var stops: [GradientStop] = [
        .init(color: .init(red: 0.05, green: 0.03, blue: 0.16), location: 0),
        .init(color: .init(red: 1.0, green: 0.47, blue: 0.66), location: 1),
    ]
    /// How far to carry the image toward the mapped colors, 0...1.
    var amount: CGFloat = 1

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.stops = try container.decodeIfPresent([GradientStop].self, forKey: .stops) ?? [
            GradientStop(color: RGBColor(red: 0.05, green: 0.03, blue: 0.16), location: 0),
            GradientStop(color: RGBColor(red: 1.0, green: 0.47, blue: 0.66), location: 1),
        ]
        self.amount = try container.decodeIfPresent(CGFloat.self, forKey: .amount) ?? 1
    }
}

nonisolated struct RGBColor: Codable, Hashable {
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

    /// The components Finder stores in an icon view's `backgroundColor*` keys.
    ///
    /// Those keys are calibrated RGB — Generic RGB, gamma 1.8 — which is what an
    /// `NSColor` carried before sRGB became the default, and Finder still reads them
    /// that way. Everything else here works in sRGB, so a component written straight
    /// through ships a background lighter than the canvas showed: mid-gray leaves as
    /// 0.5 and Finder draws it at sRGB 0.572, eighteen levels off.
    ///
    /// Never reduce this to a gamma adjustment. Generic RGB differs from sRGB in its
    /// primaries as well as its transfer function, and `pow(linear, 1/1.8)` misses the
    /// green of a saturated red by 33 of 255 while agreeing exactly on every gray — so a
    /// change tested on neutrals alone looks correct and is not. Finder's own stored
    /// triple for sRGB (0.9, 0.1, 0.1) is (0.863525, 0, 0.083), which is what this
    /// conversion returns to five decimal places.
    ///
    /// Generic RGB also has the smaller gamut, so a saturated color clips on the way in:
    /// that same red stores a green of exactly 0 and reads back eight levels off. A limit
    /// of the record's colorspace, not a rounding loss.
    nonisolated var finderStoredComponents: (red: Double, green: Double, blue: Double) {
        guard let generic = NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
            .usingColorSpace(.genericRGB)
        else { return (Double(red), Double(green), Double(blue)) }

        func clamped(_ value: CGFloat) -> Double { Double(min(max(value, 0), 1)) }
        return (clamped(generic.redComponent), clamped(generic.greenComponent), clamped(generic.blueComponent))
    }

    /// Reads back a color Finder stored in its `backgroundColor*` keys, so an imported
    /// DMG shows in the canvas as the color Finder was drawing.
    nonisolated init(finderStoredRed red: Double, green: Double, blue: Double) {
        let generic = NSColor(
            colorSpace: .genericRGB,
            components: [CGFloat(red), CGFloat(green), CGFloat(blue), 1],
            count: 4,
        )
        guard let srgb = generic.usingColorSpace(.sRGB) else {
            self.init(red: red, green: green, blue: blue)
            return
        }
        self.init(
            red: min(max(srgb.redComponent, 0), 1),
            green: min(max(srgb.greenComponent, 0), 1),
            blue: min(max(srgb.blueComponent, 0), 1),
        )
    }
}

// MARK: - Gradient

nonisolated struct GradientConfiguration: Codable, Hashable {
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

nonisolated enum GradientType: String, Codable, CaseIterable {
    case linear
    case radial
}

nonisolated struct GradientStop: Codable, Hashable, Identifiable {
    var id: UUID = .init()
    var color: RGBColor
    var location: CGFloat
}

// MARK: - Variable Blur

nonisolated struct VariableBlurConfiguration: Codable, Hashable {
    var radius: CGFloat = 20
    var maskType: VariableBlurMaskType = .linear
    var angle: CGFloat = 180
    var centerX: CGFloat = 0.5
    var centerY: CGFloat = 0.5
    var startPoint: CGFloat = 0.3
    var endPoint: CGFloat = 0.7
}

nonisolated enum VariableBlurMaskType: String, Codable, CaseIterable {
    case linear
    case radial
}

// MARK: - Color Adjustments

nonisolated struct ColorAdjustments: Codable, Hashable {
    var brightness: CGFloat = 0
    var contrast: CGFloat = 1
    var saturation: CGFloat = 1
    var hueRotation: CGFloat = 0
    var exposure: CGFloat = 0
}

// MARK: - Vignette

nonisolated struct VignetteConfiguration: Codable, Hashable {
    var intensity: CGFloat = 0.8
    var radius: CGFloat = 1.0
}

// MARK: - Bloom

nonisolated struct BloomConfiguration: Codable, Hashable {
    var intensity: CGFloat = 0.5
    var radius: CGFloat = 10
}

// MARK: - Shadow

nonisolated struct ShadowConfiguration: Codable, Hashable {
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

nonisolated struct BevelConfiguration: Codable, Hashable {
    var enabled: Bool = true
    var depth: CGFloat = 5
    var lightAngle: CGFloat = 135
    var intensity: CGFloat = 0.5

    init(
        enabled: Bool = true,
        depth: CGFloat = 5,
        lightAngle: CGFloat = 135,
        intensity: CGFloat = 0.5,
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

nonisolated struct TextLayerConfiguration: Codable, Hashable, Identifiable {
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

nonisolated struct SFSymbolLayerConfiguration: Codable, Hashable, Identifiable {
    var id: UUID = .init()
    var position: CGPoint
    var symbolName: String = "arrow.right"
    var pointSize: CGFloat = 48
    var weight: SFSymbolWeight = .regular
    var color: RGBColor = .init(red: 0, green: 0, blue: 0)
}

nonisolated enum SFSymbolWeight: String, Codable, CaseIterable {
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

nonisolated struct CanvasItem: Codable, Hashable, Identifiable {
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
        position: CGPoint,
    ) -> CanvasItem {
        CanvasItem(kind: .app, label: label, position: position, isPlaceholder: true)
    }

    /// Creates an unfilled folder placeholder slot at the given position — the
    /// slot a dropped folder (e.g. bundled documentation) fills.
    static func folderPlaceholder(
        label: String = folderPlaceholderLabel,
        position: CGPoint,
    ) -> CanvasItem {
        CanvasItem(kind: .folder, label: label, position: position, isPlaceholder: true)
    }

    /// Creates an unfilled file placeholder slot at the given position — the
    /// slot a dropped file (e.g. a Read Me) fills.
    static func filePlaceholder(
        label: String = filePlaceholderLabel,
        position: CGPoint,
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
    var isEmbedded: Bool {
        assetName != nil
    }

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

nonisolated struct ItemBackground: Codable, Hashable {
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
    var glass: GlassConfiguration?

    /// Whether this background puts anything on screen. The body, the shadow, and the
    /// bevel are independently switchable, so a background with `enabled == false` can
    /// still cast a shadow or carry a bevel.
    var draws: Bool {
        enabled || shadow?.enabled == true || bevel?.enabled == true || glass?.enabled == true
    }

    /// How far, in points, the rendered panel spills outside its own rect: the shadow
    /// reaches beyond it, and the body blur samples the background around it.
    var renderOutset: CGFloat {
        var outset: CGFloat = 0
        if let shadow, shadow.enabled {
            outset = max(outset, shadow.radius * 3 + max(abs(shadow.offsetX), abs(shadow.offsetY)))
        }
        if enabled, blurRadius > 0 {
            outset = max(outset, blurRadius * 3)
        }
        return ceil(outset)
    }

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
        case glass
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
        bevel: BevelConfiguration? = nil,
        glass: GlassConfiguration? = nil,
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
        self.glass = glass
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
        self.glass = try container.decodeIfPresent(GlassConfiguration.self, forKey: .glass)
    }
}

// MARK: - Glass

/// The edge treatment that reads as glass rather than as embossed plastic: a hairline
/// border brightest where the light falls, a shadow cast inward from the opposite edge,
/// and a saturation lift on whatever shows through the panel.
nonisolated struct GlassConfiguration: Codable, Hashable {
    var enabled: Bool = true
    /// Hairline border width in points.
    var borderWidth: CGFloat = 1
    /// Border opacity at the lit edge. The far edge fades to a quarter of it.
    var borderOpacity: CGFloat = 0.55
    /// Where the light comes from, in degrees.
    var lightAngle: CGFloat = 90
    /// How far the inner shadow reaches in from the unlit edge, in points.
    var innerShadowRadius: CGFloat = 12
    var innerShadowOpacity: CGFloat = 0.22
    /// Saturation applied to what shows through the panel, where 1 leaves it alone.
    var saturation: CGFloat = 1.2

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.borderWidth = try container.decodeIfPresent(CGFloat.self, forKey: .borderWidth) ?? 1
        self.borderOpacity = try container.decodeIfPresent(CGFloat.self, forKey: .borderOpacity) ?? 0.55
        self.lightAngle = try container.decodeIfPresent(CGFloat.self, forKey: .lightAngle) ?? 90
        self.innerShadowRadius = try container.decodeIfPresent(CGFloat.self, forKey: .innerShadowRadius) ?? 12
        self.innerShadowOpacity = try container.decodeIfPresent(CGFloat.self, forKey: .innerShadowOpacity) ?? 0.22
        self.saturation = try container.decodeIfPresent(CGFloat.self, forKey: .saturation) ?? 1.2
    }
}

nonisolated enum ItemBlendMode: String, Codable, CaseIterable {
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

nonisolated enum ItemLinkType: String, Codable, CaseIterable {
    case copy
    case symlink
}

nonisolated enum CanvasItemKind: String, Codable, CaseIterable {
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
            withDestinationURL: URL(filePath: "/Applications"),
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
            isSourceMissing: isSourceMissing,
        )
    }
}

// MARK: - Volume Icon

nonisolated struct VolumeIconConfiguration: Codable, Hashable {
    var type: VolumeIconType = .composed
    var sourceIconName: String?
}

nonisolated enum VolumeIconType: String, Codable, CaseIterable {
    case composed
    case custom
    case none
}

// MARK: - Code Signing

nonisolated struct CodeSignConfiguration: Codable, Hashable {
    var enabled: Bool = false
    var identity: String?
}

// MARK: - DMG Image Format

nonisolated enum DMGImageFormat: String, Codable, CaseIterable {
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

nonisolated enum DMGFilesystem: String, Codable, CaseIterable {
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

nonisolated struct WindowPosition: Codable, Hashable {
    var x: Int = 200
    var y: Int = 120
}
