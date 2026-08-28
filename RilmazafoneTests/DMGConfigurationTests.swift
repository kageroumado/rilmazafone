import CoreGraphics
import Foundation
import Testing
@testable import Rilmazafone

@Suite("DMGConfiguration")
@MainActor
struct DMGConfigurationTests {
    // MARK: - Effective Grid Spacing

    @Test
    func `Auto grid spacing: width/6 clamped to 100`() {
        var config = DMGConfiguration()
        config.isGridSpacingAuto = true
        config.window.width = 660

        // round(660/6) = 110, clamped to 100
        #expect(config.effectiveGridSpacing == 100)
    }

    @Test
    func `Auto grid spacing: narrow window below clamp`() {
        var config = DMGConfiguration()
        config.isGridSpacingAuto = true
        config.window.width = 480

        // round(480/6) = 80
        #expect(config.effectiveGridSpacing == 80)
    }

    @Test
    func `Manual grid spacing: value above 100 is clamped`() {
        var config = DMGConfiguration()
        config.isGridSpacingAuto = false
        config.gridSpacing = 120

        #expect(config.effectiveGridSpacing == 100)
    }

    @Test
    func `Manual grid spacing: value below 100 passes through`() {
        var config = DMGConfiguration()
        config.isGridSpacingAuto = false
        config.gridSpacing = 60

        #expect(config.effectiveGridSpacing == 60)
    }

    // MARK: - Codable Round-Trip

    @Test
    func `Default configuration survives JSON encode/decode`() throws {
        let original = DMGConfiguration()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DMGConfiguration.self, from: encoded)

        #expect(original == decoded)
    }

    @Test
    func `Fully populated configuration survives JSON encode/decode`() throws {
        var config = DMGConfiguration()
        config.volumeName = "My App Installer"
        config.window = WindowConfiguration(width: 800, height: 500)
        config.iconSize = 96
        config.textSize = 11
        config.gridSpacing = 75
        config.isGridSpacingAuto = false
        config.hideExtensions = false
        config.background.type = .color
        config.background.color = RGBColor(red: 0.1, green: 0.2, blue: 0.3)
        config.dmgFormat = .udzo
        config.filesystem = .hfsPlus
        config.windowPosition = WindowPosition(x: 300, y: 200)
        config.codeSign = CodeSignConfiguration(enabled: true, identity: "Developer ID")
        config.items = [
            CanvasItem(kind: .app, label: "MyApp.app", sourcePath: "/tmp/MyApp.app", position: CGPoint(x: 100, y: 200)),
            CanvasItem(kind: .applicationsSymlink, label: "Applications", position: CGPoint(x: 500, y: 200)),
        ]
        config.textLayers = [
            TextLayerConfiguration(
                text: "Drag here",
                position: CGPoint(x: 300, y: 50),
                fontFamily: "SF Pro",
                fontSize: 18,
                isBold: true,
                color: RGBColor(red: 1, green: 1, blue: 1),
            ),
        ]
        config.sfSymbolLayers = [
            SFSymbolLayerConfiguration(
                position: CGPoint(x: 300, y: 200),
                symbolName: "arrow.right",
                pointSize: 64,
                weight: .bold,
                color: RGBColor(red: 0.5, green: 0.5, blue: 0.5),
            ),
        ]

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(DMGConfiguration.self, from: encoded)

        #expect(config == decoded)
    }

    @Test
    func `Decoding empty JSON uses all defaults`() throws {
        let emptyJSON = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(DMGConfiguration.self, from: emptyJSON)

        #expect(decoded.volumeName == "Untitled")
        #expect(decoded.window.width == 660)
        #expect(decoded.window.height == 400)
        #expect(decoded.iconSize == 160)
        #expect(decoded.textSize == 13)
        #expect(decoded.gridSpacing == 100)
        #expect(decoded.isGridSpacingAuto == true)
        #expect(decoded.hideExtensions == true)
        #expect(decoded.background.type == .none)
        #expect(decoded.items.isEmpty)
        #expect(decoded.textLayers.isEmpty)
        #expect(decoded.sfSymbolLayers.isEmpty)
        #expect(decoded.dmgFormat == .ulfo)
        #expect(decoded.filesystem == .apfs)
    }

    // MARK: - Path Abbreviation

    @Test
    func `abbreviatePaths and expandAbbreviatedPaths round-trip`() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var config = DMGConfiguration()
        config.items = [
            CanvasItem(kind: .app, label: "App.app", sourcePath: "\(home)/Apps/MyApp.app", position: .zero),
            CanvasItem(kind: .file, label: "README", sourcePath: "/usr/local/share/readme.txt", position: .zero),
        ]

        let originalPaths = config.items.map(\.sourcePath)

        config.abbreviatePaths()
        #expect(config.items[0].sourcePath == "~/Apps/MyApp.app")
        #expect(config.items[1].sourcePath == "/usr/local/share/readme.txt") // Non-home path unchanged

        config.expandAbbreviatedPaths()
        #expect(config.items.map(\.sourcePath) == originalPaths)
    }

    @Test
    func `abbreviatePaths does not modify nil source paths`() {
        var config = DMGConfiguration()
        config.items = [
            CanvasItem(kind: .applicationsSymlink, label: "Applications", position: .zero),
        ]

        config.abbreviatePaths()
        #expect(config.items[0].sourcePath == nil)
    }

    // MARK: - Gradient Configuration

    @Test
    func `Gradient default stops`() {
        let gradient = GradientConfiguration()

        #expect(gradient.stops.count == 2)
        #expect(gradient.stops[0].location == 0)
        #expect(gradient.stops[1].location == 1)
        #expect(gradient.type == .linear)
        #expect(gradient.angle == 180)
    }

    // MARK: - Finder Background Color

    /// Finder reads an icon view's `backgroundColor*` keys as calibrated RGB — Generic
    /// RGB, gamma 1.8 — while the document holds sRGB. Written through unconverted, a
    /// mid-gray background ships eighteen levels lighter than the canvas showed it.
    @Test
    func `A mid-gray background stores darker than its sRGB value`() {
        let stored = RGBColor(red: 0.5, green: 0.5, blue: 0.5).finderStoredComponents

        #expect(abs(stored.red - 0.42468) < 0.0001)
        #expect(stored.red == stored.green)
        #expect(stored.green == stored.blue)
    }

    /// Reading is the same conversion backwards, so an imported DMG shows the color
    /// Finder was actually drawing rather than a darker one.
    @Test
    func `A Finder-stored background reads back as the color Finder draws`() {
        let read = RGBColor(finderStoredRed: 0.42468, green: 0.42468, blue: 0.42468)

        #expect(abs(read.red - 0.5) < 0.0001)
        #expect(abs(read.green - 0.5) < 0.0001)
        #expect(abs(read.blue - 0.5) < 0.0001)
    }

    @Test(arguments: [
        RGBColor(red: 0, green: 0, blue: 0),
        RGBColor(red: 1, green: 1, blue: 1),
        RGBColor(red: 0.5, green: 0.5, blue: 0.5),
        RGBColor(red: 0.07, green: 0.07, blue: 0.09),
        RGBColor(red: 0.2, green: 0.8, blue: 0.3),
    ])
    func `Writing a background color and reading it back is lossless`(color: RGBColor) {
        let stored = color.finderStoredComponents
        let read = RGBColor(finderStoredRed: stored.red, green: stored.green, blue: stored.blue)

        // One 8-bit step of slack: the conversion runs through a narrower gamut, so an
        // exact match is not available for every color the document can hold.
        #expect(abs(read.red - color.red) < 1.0 / 255)
        #expect(abs(read.green - color.green) < 1.0 / 255)
        #expect(abs(read.blue - color.blue) < 1.0 / 255)
    }
}
