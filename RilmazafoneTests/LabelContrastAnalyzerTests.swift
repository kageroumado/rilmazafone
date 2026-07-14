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
        itemCount: Int
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
                    y: 190
                )
            )
        }
        return config
    }

    static func analyze(_ configuration: DMGConfiguration) -> Set<LegibilityWarning> {
        LabelContrastAnalyzer.analyze(
            input: LegibilityAnalysisInput(configuration: configuration, layerImages: [:])
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
        second: UInt8
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
        encodedGray: (Int, Int) -> UInt8
    ) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
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

    @Test("White background flags every item for dark mode and none for light")
    func whiteBackgroundFlagsDarkOnly() {
        let config = Self.solidBackgroundConfiguration(
            color: RGBColor(red: 1, green: 1, blue: 1),
            itemCount: 3
        )
        let warnings = Self.analyze(config)

        for item in config.items {
            #expect(warnings.contains(LegibilityWarning(itemID: item.id, mode: .dark)))
            #expect(!warnings.contains(LegibilityWarning(itemID: item.id, mode: .light)))
        }
    }

    @Test("Black background flags every item for light mode and none for dark")
    func blackBackgroundFlagsLightOnly() {
        let config = Self.solidBackgroundConfiguration(
            color: RGBColor(red: 0, green: 0, blue: 0),
            itemCount: 3
        )
        let warnings = Self.analyze(config)

        for item in config.items {
            #expect(warnings.contains(LegibilityWarning(itemID: item.id, mode: .light)))
            #expect(!warnings.contains(LegibilityWarning(itemID: item.id, mode: .dark)))
        }
    }

    @Test("Mid-gray background passes both modes when flat")
    func midGrayPassesBothModes() {
        let config = Self.solidBackgroundConfiguration(
            color: RGBColor(red: 0.5, green: 0.5, blue: 0.5),
            itemCount: 2
        )
        #expect(Self.analyze(config).isEmpty)
    }

    // MARK: - Phase Acceptance: panel remediation

    @Test("Adding a dark glass panel behind a flagged label clears its dark-mode warning")
    func darkGlassPanelClearsDarkWarning() {
        var config = Self.solidBackgroundConfiguration(
            color: RGBColor(red: 1, green: 1, blue: 1),
            itemCount: 1
        )
        let itemID = config.items[0].id

        let before = Self.analyze(config)
        #expect(before.contains(LegibilityWarning(itemID: itemID, mode: .dark)))

        config.items[0].background = ItemBackground(
            enabled: true,
            color: RGBColor(red: 0, green: 0, blue: 0),
            opacity: 0.6,
            blurRadius: 20
        )
        let after = Self.analyze(config)
        #expect(!after.contains(LegibilityWarning(itemID: itemID, mode: .dark)))
        #expect(!after.contains(LegibilityWarning(itemID: itemID, mode: .light)))
    }

    // MARK: - Placeholders

    @Test("Placeholder items are analyzed at their position")
    func placeholdersAreAnalyzed() {
        var config = Self.solidBackgroundConfiguration(
            color: RGBColor(red: 1, green: 1, blue: 1),
            itemCount: 0
        )
        let placeholder = CanvasItem.appPlaceholder(position: CGPoint(x: 220, y: 190))
        config.items = [placeholder]

        let warnings = Self.analyze(config)
        #expect(warnings.contains(LegibilityWarning(itemID: placeholder.id, mode: .dark)))
    }

    // MARK: - Variance penalty

    @Test("Busy checker flags earlier than a flat background at the same mean luminance")
    func busyFlagsEarlierThanFlat() throws {
        let windowSize = CGSize(width: 660, height: 400)
        let item = CanvasItem(kind: .app, label: "App.app", position: CGPoint(x: 330, y: 190))

        // Encoded 141 has linear luminance ~0.266 — the same mean as a 26/191
        // checker — giving a flat dark-mode ratio of ~3.3:1: above the 3.0 base
        // threshold, below the 4.5 busy ceiling.
        let flat = try #require(Self.makeFlatImage(width: 660, height: 400, encodedGray: 141))
        let checker = try #require(
            Self.makeCheckerImage(width: 660, height: 400, first: 26, second: 191)
        )

        let flatWarnings = LabelContrastAnalyzer.analyze(
            composite: flat, items: [item], iconSize: 160, textSize: 13, windowSize: windowSize
        )
        let busyWarnings = LabelContrastAnalyzer.analyze(
            composite: checker, items: [item], iconSize: 160, textSize: 13, windowSize: windowSize
        )

        #expect(!flatWarnings.contains(LegibilityWarning(itemID: item.id, mode: .dark)))
        #expect(busyWarnings.contains(LegibilityWarning(itemID: item.id, mode: .dark)))
    }

    // MARK: - Geometry

    @Test("Label rect sits just below the icon cell and matches canvas metrics")
    func labelRectGeometry() {
        let rect = LabelContrastAnalyzer.labelRect(
            position: CGPoint(x: 330, y: 200),
            iconSize: 160,
            textSize: 13
        )
        // Block height = 160 + 20 + 4 + 20 = 204; block top = 200 - 102 = 98;
        // label top = 98 + 180 + 4 = 282; width = iconSize + 40; two 17 pt lines.
        #expect(rect.minY == 282)
        #expect(rect.width == 200)
        #expect(rect.midX == 330)
        #expect(rect.height == 34)
    }

    // MARK: - Bundled templates

    @Test("Bundled templates produce zero legibility warnings")
    func bundledTemplatesHaveZeroWarnings() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let templatesDir = repoRoot.appending(path: "Rilmazafone/Resources/Templates")

        guard FileManager.default.fileExists(atPath: templatesDir.path) else {
            print(
                "SKIPPED: bundled templates not present in this tree "
                    + "(\(templatesDir.path) missing); re-run after the templates branch merges."
            )
            return
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: templatesDir, includingPropertiesForKeys: nil
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
                input: LegibilityAnalysisInput(configuration: config, layerImages: layerImages)
            )
            #expect(
                warnings.isEmpty,
                "Template \(entry.lastPathComponent) unexpectedly flagged: \(warnings)"
            )
            analyzedCount += 1
        }

        if analyzedCount == 0 {
            print(
                "SKIPPED: template directory exists but contained no parseable "
                    + "document.json packages; re-run after the templates branch merges."
            )
        }
    }

    // MARK: - Performance & isolation

    @Test("4K-equivalent pass with 8 items completes under 150 ms off the main thread")
    func fourKPassStaysUnderBudgetOffMain() async throws {
        let items = (0 ..< 8).map { index in
            CanvasItem(
                kind: .app,
                label: "Item \(index).app",
                position: CGPoint(x: 160 + index * 220, y: 540)
            )
        }

        // Assertions happen back on the test after the hop; results cross as a
        // Sendable tuple so failures attribute to this test, not to the task.
        let probe: (wasOffMain: Bool, elapsed: Duration, warnings: Set<LegibilityWarning>)? =
            await Task.detached(name: "Legibility Perf Probe") {
                guard let composite = LabelContrastAnalyzerTests.makeFlatImage(
                    width: 3840, height: 2160, encodedGray: 255
                ) else { return nil }

                let wasOffMain = !LabelContrastAnalyzerTests.isOnMainThread()
                let clock = ContinuousClock()
                var warnings: Set<LegibilityWarning> = []
                let elapsed = clock.measure {
                    warnings = LabelContrastAnalyzer.analyze(
                        composite: composite,
                        items: items,
                        iconSize: 160,
                        textSize: 13,
                        windowSize: CGSize(width: 1920, height: 1080)
                    )
                }
                return (wasOffMain, elapsed, warnings)
            }.value

        let result = try #require(probe)
        print("Measured 4K analysis pass: \(result.elapsed)")
        #expect(result.wasOffMain, "Analysis core must be runnable off the main thread")
        #expect(result.elapsed < .milliseconds(150))
        // White composite: every item flags for dark mode, none for light.
        #expect(result.warnings == Set(items.map { LegibilityWarning(itemID: $0.id, mode: .dark) }))
    }
}
