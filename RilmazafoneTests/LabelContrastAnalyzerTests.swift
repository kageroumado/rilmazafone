import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Rilmazafone

@Suite("LabelContrastAnalyzer")
@MainActor
struct LabelContrastAnalyzerTests {
    // MARK: - Fixtures

    /// Disambiguated from QuickDraw's `RGBColor`, which AppKit drags into scope.
    typealias RGBColor = Rilmazafone.RGBColor

    /// A solid-color-background configuration with `itemCount` items spread
    /// horizontally across a 660×400 window at default icon/text sizes.
    static func solidBackgroundConfiguration(
        color: RGBColor,
        itemCount: Int,
    ) -> DMGConfiguration {
        var config = DMGConfiguration()
        config.window = WindowConfiguration(width: 660, height: 400)
        config.background.type = .color
        config.background.color = color
        config.items = (0 ..< itemCount).map { index in
            CanvasItem(
                kind: .app,
                label: "Item \(index).app",
                position: CGPoint(
                    x: CGFloat(index + 1) * 660 / CGFloat(itemCount + 1),
                    y: 190,
                ),
            )
        }
        return config
    }

    static func analyze(_ configuration: DMGConfiguration) -> Set<UUID> {
        LabelContrastAnalyzer.analyze(
            input: LegibilityAnalysisInput(configuration: configuration, layerImages: [:]),
        )
    }

    /// Flat gray RGBA8 image at the given encoded sRGB byte value.
    nonisolated static func makeFlatImage(width: Int, height: Int, encodedGray: UInt8) -> CGImage? {
        makeImage(width: width, height: height) { _, _ in encodedGray }
    }

    /// 8×8-block checkerboard alternating between two encoded sRGB byte values.
    nonisolated static func makeCheckerImage(
        width: Int,
        height: Int,
        first: UInt8,
        second: UInt8,
    ) -> CGImage? {
        makeImage(width: width, height: height) { x, y in
            (x / 8 + y / 8).isMultiple(of: 2) ? first : second
        }
    }

    /// Synchronous wrapper because `Thread.isMainThread` is unavailable directly
    /// from async contexts.
    nonisolated static func isOnMainThread() -> Bool {
        Thread.isMainThread
    }

    nonisolated static func makeImage(
        width: Int,
        height: Int,
        encodedGray: (Int, Int) -> UInt8,
    ) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
              ),
              let data = context.data
        else { return nil }

        let bytesPerRow = context.bytesPerRow
        let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
        for y in 0 ..< height {
            let row = buffer + y * bytesPerRow
            for x in 0 ..< width {
                let value = encodedGray(x, y)
                let pixel = row + x * 4
                pixel[0] = value
                pixel[1] = value
                pixel[2] = value
                pixel[3] = 255
            }
        }
        return context.makeImage()
    }

    // MARK: - Phase Acceptance: solid backgrounds

    /// Finder draws the labels dark whatever the appearance, so a white background is
    /// the readable one and stays readable — there is no appearance in which white
    /// behind dark text becomes a problem.
    @Test
    func `A white background flags nothing`() {
        let config = Self.solidBackgroundConfiguration(
            color: RGBColor(red: 1, green: 1, blue: 1),
            itemCount: 3,
        )
        #expect(Self.analyze(config).isEmpty)
    }

    /// The failure this analysis exists to catch: dark text on a dark background, which
    /// Dark Mode does not rescue because the label never turns white.
    @Test
    func `A black background flags every item`() {
        let config = Self.solidBackgroundConfiguration(
            color: RGBColor(red: 0, green: 0, blue: 0),
            itemCount: 3,
        )
        let warnings = Self.analyze(config)

        for item in config.items {
            #expect(warnings.contains(item.id))
        }
    }

    @Test
    func `A flat mid-gray background passes`() {
        let config = Self.solidBackgroundConfiguration(
            color: RGBColor(red: 0.5, green: 0.5, blue: 0.5),
            itemCount: 2,
        )
        #expect(Self.analyze(config).isEmpty)
    }

    /// Without a custom background Finder draws its own window fill and picks a label
    /// color to suit it, so nothing here can be unreadable and nothing should be flagged.
    @Test
    func `A volume with no custom background flags nothing`() {
        var config = Self.solidBackgroundConfiguration(
            color: RGBColor(red: 0, green: 0, blue: 0),
            itemCount: 2,
        )
        config.background.type = .none

        #expect(!config.finderPinsLabelColor)
        #expect(Self.analyze(config).isEmpty)
    }

    // MARK: - Phase Acceptance: panel remediation

    /// Lightening is the only direction that helps a dark label, which is what the
    /// chip's one-click remediation now installs.
    @Test
    func `Adding a white glass panel behind a flagged label clears its warning`() {
        var config = Self.solidBackgroundConfiguration(
            color: RGBColor(red: 0, green: 0, blue: 0),
            itemCount: 1,
        )
        let itemID = config.items[0].id
        #expect(Self.analyze(config).contains(itemID))

        config.items[0].background = ItemBackground(
            enabled: true,
            color: RGBColor(red: 1, green: 1, blue: 1),
            opacity: 0.6,
            blurRadius: 20,
        )
        #expect(!Self.analyze(config).contains(itemID))
    }

    // MARK: - Placeholders

    @Test
    func `Placeholder items are analyzed at their position`() {
        var config = Self.solidBackgroundConfiguration(
            color: RGBColor(red: 0, green: 0, blue: 0),
            itemCount: 0,
        )
        let placeholder = CanvasItem.appPlaceholder(position: CGPoint(x: 220, y: 190))
        config.items = [placeholder]

        #expect(Self.analyze(config).contains(placeholder.id))
    }

    // MARK: - Variance penalty

    @Test
    func `Busy checker flags earlier than a flat background at the same mean luminance`() throws {
        let windowSize = CGSize(width: 660, height: 400)
        let item = CanvasItem(kind: .app, label: "App.app", position: CGPoint(x: 330, y: 190))

        // Encoded 95 has linear luminance ~0.114 — the same mean as a 0/132 checker —
        // giving a ratio against the dark label of ~3.3:1: above the 3.0 base threshold,
        // and below the ~3.7:1 the checker's variance raises the threshold to.
        let flat = try #require(Self.makeFlatImage(width: 660, height: 400, encodedGray: 95))
        let checker = try #require(
            Self.makeCheckerImage(width: 660, height: 400, first: 0, second: 132),
        )

        let flatWarnings = LabelContrastAnalyzer.analyze(
            composite: flat, items: [item], iconSize: 160, textSize: 13, windowSize: windowSize,
        )
        let busyWarnings = LabelContrastAnalyzer.analyze(
            composite: checker, items: [item], iconSize: 160, textSize: 13, windowSize: windowSize,
        )

        #expect(!flatWarnings.contains(item.id))
        #expect(busyWarnings.contains(item.id))
    }

    // MARK: - Geometry

    @Test
    func `Label rect sits just below the icon cell and matches canvas metrics`() {
        let rect = LabelContrastAnalyzer.labelRect(
            position: CGPoint(x: 330, y: 200),
            iconSize: 160,
            textSize: 13,
        )
        // Block height = 160 + 20 + 4 + 20 = 204; block top = 200 - 102 = 98;
        // label top = 98 + 180 + 4 = 282; width = iconSize + 40; two 17 pt lines.
        #expect(rect.minY == 282)
        #expect(rect.width == 200)
        #expect(rect.midX == 330)
        #expect(rect.height == 34)
    }

    // MARK: - Bundled templates

    @Test
    func `Bundled templates produce zero legibility warnings`() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let templatesDir = repoRoot.appending(path: "Rilmazafone/Resources/Templates")

        guard FileManager.default.fileExists(atPath: templatesDir.path) else {
            print(
                "SKIPPED: bundled templates not present in this tree "
                    + "(\(templatesDir.path) missing); re-run after the templates branch merges.",
            )
            return
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: templatesDir, includingPropertiesForKeys: nil,
        )
        var analyzedCount = 0
        for entry in entries {
            let manifest = entry.appending(path: "document.json")
            guard let data = try? Data(contentsOf: manifest),
                  var config = try? JSONDecoder().decode(DMGConfiguration.self, from: data)
            else { continue }
            config.expandAbbreviatedPaths()

            var layerImages: [UUID: NSImage] = [:]
            for layer in config.background.layers {
                let assetURL = entry.appending(path: "Assets").appending(path: layer.imageName)
                if let image = NSImage(contentsOf: assetURL) {
                    layerImages[layer.id] = image
                }
            }

            let warnings = LabelContrastAnalyzer.analyze(
                input: LegibilityAnalysisInput(configuration: config, layerImages: layerImages),
            )
            #expect(
                warnings.isEmpty,
                "Template \(entry.lastPathComponent) unexpectedly flagged: \(warnings)",
            )
            analyzedCount += 1
        }

        if analyzedCount == 0 {
            print(
                "SKIPPED: template directory exists but contained no parseable "
                    + "document.json packages; re-run after the templates branch merges.",
            )
        }
    }

    // MARK: - Performance & isolation

    @Test
    func `4K-equivalent pass with 8 items completes under 150 ms off the main thread`() async throws {
        let items = (0 ..< 8).map { index in
            CanvasItem(
                kind: .app,
                label: "Item \(index).app",
                position: CGPoint(x: 160 + index * 220, y: 540),
            )
        }

        // Assertions happen back on the test after the hop; results cross as a
        // Sendable tuple so failures attribute to this test, not to the task.
        let probe: (wasOffMain: Bool, elapsed: Duration, warnings: Set<UUID>)? =
            await Task.detached(name: "Legibility Perf Probe") {
                guard let composite = LabelContrastAnalyzerTests.makeFlatImage(
                    width: 3_840, height: 2_160, encodedGray: 0,
                ) else { return nil }

                let wasOffMain = !LabelContrastAnalyzerTests.isOnMainThread()
                let clock = ContinuousClock()
                var warnings: Set<UUID> = []
                let elapsed = clock.measure {
                    warnings = LabelContrastAnalyzer.analyze(
                        composite: composite,
                        items: items,
                        iconSize: 160,
                        textSize: 13,
                        windowSize: CGSize(width: 1_920, height: 1_080),
                    )
                }
                return (wasOffMain, elapsed, warnings)
            }.value

        let result = try #require(probe)
        print("Measured 4K analysis pass: \(result.elapsed)")
        #expect(result.wasOffMain, "Analysis core must be runnable off the main thread")
        #expect(result.elapsed < .milliseconds(150))
        // Black composite behind dark labels: every item flags.
        #expect(result.warnings == Set(items.map(\.id)))
    }
}
