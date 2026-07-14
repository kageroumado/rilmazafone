import AppKit
import Foundation
import Testing
@testable import Rilmazafone

/// Shared access to the bundled template set. The test target hosts the app, so
/// `Bundle.main` is the built `Rilmazafone.app` and the enumeration exercises the
/// exact resource layout the app ships: `Contents/Resources/Templates/*.dmgtemplate`.
/// Tests are parameterized over this enumeration so future templates are covered
/// automatically.
enum BundledTemplates {
    /// Names the bundled template set must contain. More may be added later.
    static let requiredNames = [
        "Aurora", "Classic", "Compact", "Cosmos", "Editorial", "Glass",
        "Graphite", "Snow Leopard", "Toolbox",
    ]

    static let templatesDirectory = Bundle.main.resourceURL!.appending(path: "Templates")

    static let urls: [URL] = {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: templatesDirectory,
            includingPropertiesForKeys: nil,
        )) ?? []
        return contents
            .filter { $0.pathExtension == "dmgtemplate" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

    /// Loads a template the way the document read path does. `ReferenceFileDocument`'s
    /// `ReadConfiguration` has no public initializer, so this mirrors
    /// `RilmazafoneDocument.init(configuration:)` exactly: directory `FileWrapper` →
    /// `document.json` regular-file contents → `JSONDecoder` → `expandAbbreviatedPaths()`.
    static func load(_ url: URL) throws -> DMGConfiguration {
        let wrapper = try FileWrapper(url: url, options: .immediate)
        guard wrapper.isDirectory,
              let manifest = wrapper.fileWrappers?["document.json"],
              let data = manifest.regularFileContents
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var decoded = try JSONDecoder().decode(DMGConfiguration.self, from: data)
        decoded.expandAbbreviatedPaths()
        return decoded
    }

    /// WCAG relative luminance of one sRGB pixel.
    static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Mean relative luminance of the Finder-label region under an item's icon:
    /// icon-width × ~2 text lines, starting just below the icon cell. Canvas item
    /// coordinates are top-down, matching `CGImage` row order, so no flip is needed.
    static func meanLabelLuminance(
        image: CGImage,
        configuration: DMGConfiguration,
        item: CanvasItem,
    ) -> Double? {
        let labelRect = CGRect(
            x: item.position.x - configuration.iconSize / 2,
            y: item.position.y + configuration.iconSize / 2 - 2,
            width: configuration.iconSize,
            height: 2 * (configuration.textSize + 4),
        ).integral
        guard let cropped = image.cropping(to: labelRect),
              let data = cropped.dataProvider?.data as Data?
        else { return nil }

        let bytesPerPixel = cropped.bitsPerPixel / 8
        let bytesPerRow = cropped.bytesPerRow
        var total = 0.0
        var count = 0
        for y in 0 ..< cropped.height {
            for x in 0 ..< cropped.width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                total += relativeLuminance(
                    red: Double(data[offset]) / 255,
                    green: Double(data[offset + 1]) / 255,
                    blue: Double(data[offset + 2]) / 255,
                )
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return total / Double(count)
    }

    /// The deterministic 1x bitmap of the full composite (background, text, symbols,
    /// item panels) — the same pixels the baked DMG background ships.
    static func composite1x(configuration: DMGConfiguration, assetsDirectory: URL) -> CGImage? {
        guard let image = CompositeRenderer.renderBackground(
            configuration: configuration, assetsDirectory: assetsDirectory,
        ) else { return nil }
        let rep = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .first { $0.pixelsWide == Int(configuration.window.width) }
        return rep?.cgImage
    }

    static func makeTempDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "rilmazafone-template-test-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("Bundled templates")
struct BundledTemplateTests {
    @Test
    func `all required templates are bundled`() {
        let names = BundledTemplates.urls.map { $0.deletingPathExtension().lastPathComponent }
        for required in BundledTemplates.requiredNames {
            #expect(names.contains(required), "missing bundled template \(required)")
        }
    }

    // MARK: - 1. Document read path

    @Test(arguments: BundledTemplates.urls)
    func `loads through the document read path`(url: URL) throws {
        let config = try BundledTemplates.load(url)

        // Every template ships at least one placeholder slot (always an app slot),
        // and every placeholder is data-only — no baked-in source path or bookmark.
        let placeholders = config.items.filter(\.isPlaceholder)
        #expect(!placeholders.isEmpty, "expected at least one placeholder slot")
        #expect(placeholders.contains { $0.kind == .app }, "expected an app placeholder slot")
        for placeholder in placeholders {
            #expect(placeholder.sourcePath == nil, "placeholder slots must be data-only")
            #expect(placeholder.sourceBookmark == nil)
        }

        // Exactly one Applications symlink, and no filled item carries a source
        // (templates never bundle a real filesystem reference).
        let symlinks = config.items.filter { $0.kind == .applicationsSymlink }
        #expect(symlinks.count == 1, "expected exactly one Applications symlink")
        for item in config.items where !item.isPlaceholder {
            #expect(item.sourcePath == nil, "\(item.label) must not bundle a source path")
            #expect(item.sourceBookmark == nil)
        }

        #expect(config.items.count >= 2)
        #expect(!config.volumeName.isEmpty)
        #expect(config.window.width > 0 && config.window.height > 0)

        // Image-backed templates reference assets that must exist on disk; every
        // other template stays layer-free.
        if config.background.type == .image {
            #expect(!config.background.layers.isEmpty, "an image template must have layers")
            let assets = url.appending(path: "Assets")
            for layer in config.background.layers {
                let asset = assets.appending(path: layer.imageName)
                #expect(
                    FileManager.default.fileExists(atPath: asset.path),
                    "missing asset \(layer.imageName) for \(url.lastPathComponent)",
                )
            }
        } else {
            #expect(config.background.layers.isEmpty, "non-image templates must not reference assets")
        }
    }

    // MARK: - 2. Open budget

    @Test(
        arguments: BundledTemplates.urls,
    )
    func `decodes and renders a thumbnail composite within the open budget`(url: URL) throws {
        // Warm CompositeRenderer's static CI context once so the measurement reflects
        // steady-state opens (the chooser/app process is warm), not one-time setup.
        var warmup = DMGConfiguration()
        warmup.window = WindowConfiguration(width: 8, height: 8)
        warmup.background.type = .gradient
        warmup.background.gradient = GradientConfiguration()
        _ = CompositeRenderer.renderPanelBackdrop(configuration: warmup, layerImages: [:], scale: 1)

        let data = try Data(contentsOf: url.appending(path: "document.json"))

        let clock = ContinuousClock()
        let elapsed = try clock.measure {
            var config = try JSONDecoder().decode(DMGConfiguration.self, from: data)
            config.expandAbbreviatedPaths()
            let thumbnail = CompositeRenderer.renderPanelBackdrop(
                configuration: config, layerImages: [:], scale: 0.25,
            )
            #expect(thumbnail != nil)
        }
        #expect(elapsed < .milliseconds(100), "template open took \(elapsed)")
    }

    // MARK: - 4. Legibility guard

    /// Proxy for Phase 4's contrast analyzer: the label region under each item must
    /// not sit in the mid-luminance zone where neither black (light mode) nor white
    /// (dark mode) Finder labels read. Heuristic: mean WCAG relative luminance of the
    /// label rect must be clearly light (> 0.65 — black labels read) or clearly dark
    /// (< 0.35 — white labels read). Items with an enabled panel are exempt: the panel
    /// itself is the remediation the analyzer will suggest, and it repaints the label
    /// region deliberately. This is a smoke check, not the real analyzer.
    @Test(arguments: BundledTemplates.urls)
    func `label regions avoid the mid-luminance zone`(url: URL) throws {
        let config = try BundledTemplates.load(url)
        let assets = try BundledTemplates.makeTempDirectory("legibility")
        defer { try? FileManager.default.removeItem(at: assets) }

        let renderedComposite = BundledTemplates.composite1x(configuration: config, assetsDirectory: assets)
        let composite = try #require(renderedComposite)
        for item in config.items where item.background?.enabled != true {
            let measured = BundledTemplates.meanLabelLuminance(
                image: composite, configuration: config, item: item,
            )
            let luminance = try #require(measured)
            #expect(
                luminance > 0.65 || luminance < 0.35,
                "\(url.lastPathComponent) / \(item.label): label-region luminance \(luminance) is in the dangerous mid-zone",
            )
        }
    }
}

// MARK: - 3. Build integration

@Suite("Bundled templates build valid DMGs", .serialized)
struct BundledTemplateBuildTests {
    private static let fillerApp = "/System/Applications/Calculator.app"

    @Test(
        .timeLimit(.minutes(2)),
        arguments: BundledTemplates.urls,
    )
    func `builds a mountable DMG after filling every placeholder`(url: URL) async throws {
        var config = try BundledTemplates.load(url)

        let fm = FileManager.default

        // Temp sources for the folder/file slots that multi-element templates carry.
        let sourceDir = try BundledTemplates.makeTempDirectory("fill-sources")
        defer { try? fm.removeItem(at: sourceDir) }
        let docsFolder = sourceDir.appending(path: "Documentation")
        try fm.createDirectory(at: docsFolder, withIntermediateDirectories: true)
        try "guide".write(to: docsFolder.appending(path: "Guide.txt"), atomically: true, encoding: .utf8)
        let readmeFile = sourceDir.appending(path: "Read Me.txt")
        try "read me".write(to: readmeFile, atomically: true, encoding: .utf8)

        // Fill every placeholder by kind, as fillPlaceholder would. Track the
        // resulting item labels so the mount can verify each landed on the volume.
        var expectedNames = ["Applications"]
        for index in config.items.indices where config.items[index].isPlaceholder {
            let source: URL = switch config.items[index].kind {
            case .app: URL(fileURLWithPath: Self.fillerApp)
            case .folder: docsFolder
            default: readmeFile
            }
            config.items[index].label = source.lastPathComponent
            config.items[index].sourcePath = source.path
            config.items[index].isPlaceholder = false
            expectedNames.append(source.lastPathComponent)
        }
        #expect(!config.items.contains { $0.isPlaceholder }, "all slots must be filled")

        // One representative format per template for suite speed (templates ship
        // ULFO/APFS; leave them as authored).
        #expect(config.dmgFormat == .ulfo)
        #expect(config.filesystem == .apfs)

        let assets = try BundledTemplates.makeTempDirectory("build-assets")
        // Image-backed templates bake their layer assets into the background, so
        // the build needs them staged in the assets directory it reads from.
        let templateAssets = url.appending(path: "Assets")
        if fm.fileExists(atPath: templateAssets.path) {
            for asset in try fm.contentsOfDirectory(at: templateAssets, includingPropertiesForKeys: nil) {
                try fm.copyItem(at: asset, to: assets.appending(path: asset.lastPathComponent))
            }
        }
        let outputDir = try BundledTemplates.makeTempDirectory("build-out")
        let output = outputDir.appending(path: "\(url.deletingPathExtension().lastPathComponent).dmg")
        defer {
            try? fm.removeItem(at: assets)
            try? fm.removeItem(at: outputDir)
        }

        try await DMGBuildPipeline.build(
            configuration: config,
            assetsDirectory: assets,
            outputURL: output,
        ) { _ in }

        #expect(fm.fileExists(atPath: output.path))

        // Mount and verify contents; always detach so `hdiutil info` ends clean.
        let mountPoint = try BundledTemplates.makeTempDirectory("mount")
        defer { try? fm.removeItem(at: mountPoint) }

        let attach = try Process.run(
            URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: [
                "attach", output.path,
                "-noautoopen", "-nobrowse", "-noverify",
                "-mountpoint", mountPoint.path,
            ],
        )
        attach.waitUntilExit()
        #expect(attach.terminationStatus == 0)

        defer {
            let detach = try? Process.run(
                URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["detach", mountPoint.path, "-force"],
            )
            detach?.waitUntilExit()
            #expect(detach?.terminationStatus == 0, "volume failed to detach cleanly")
        }

        // Every filled item (app, Applications symlink, plus any folder/file
        // slots on the multi-element templates) must land on the volume.
        for name in expectedNames {
            #expect(
                fm.fileExists(atPath: mountPoint.appending(path: name).path),
                "\(url.lastPathComponent): expected \(name) on the volume",
            )
        }
        #expect(fm.fileExists(atPath: mountPoint.appending(path: ".DS_Store").path))
        // Every bundled template has a composite background (gradient, text, symbols,
        // or panels), so the baked background must be on the volume.
        #expect(fm.fileExists(
            atPath: mountPoint.appending(path: ".background/background.tiff").path,
        ))
    }
}
