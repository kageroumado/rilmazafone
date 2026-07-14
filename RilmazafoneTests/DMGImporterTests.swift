import CoreGraphics
import Foundation
import Testing
@testable import Rilmazafone

@Suite("DMGImporter", .serialized)
struct DMGImporterTests {
    // MARK: - Round Trip

    @Test(
        "Round-trip: importing a built DMG reproduces the design",
        .timeLimit(.minutes(3))
    )
    func roundTripImport() async throws {
        let fixture = try makeTinyApp()
        defer { cleanup(fixture.root) }

        var config = DMGConfiguration()
        config.volumeName = "RoundTrip"
        config.window = WindowConfiguration(width: 600, height: 420)
        config.windowPosition = WindowPosition(x: 250, y: 140)
        config.iconSize = 96
        config.textSize = 12
        config.dmgFormat = .udzo
        config.filesystem = .hfsPlus
        config.volumeIcon = VolumeIconConfiguration(type: .none)
        config.background.type = .gradient
        config.background.gradient = GradientConfiguration()
        config.textLayers = [
            TextLayerConfiguration(text: "Drag to install", position: CGPoint(x: 300, y: 60)),
        ]
        config.items = [
            CanvasItem(
                kind: .app,
                label: "Tiny.app",
                sourcePath: fixture.app.path,
                position: CGPoint(x: 150, y: 210)
            ),
            CanvasItem(
                kind: .applicationsSymlink,
                label: "Applications",
                position: CGPoint(x: 450, y: 210)
            ),
        ]

        let assetsDir = tempDir("roundtrip-assets")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let outputDMG = tempPath("roundtrip", extension: "dmg")
        defer {
            cleanup(assetsDir)
            cleanup(outputDMG)
        }

        try await DMGBuildPipeline.build(
            configuration: config,
            assetsDirectory: assetsDir,
            outputURL: outputDMG,
            progress: { _ in }
        )

        let result = try await DMGImporter.importLayout(of: outputDMG)
        let imported = result.configuration

        #expect(imported.volumeName == "RoundTrip")
        #expect(imported.window == config.window)
        #expect(imported.windowPosition == config.windowPosition)
        #expect(imported.iconSize == 96)
        #expect(imported.textSize == 12)
        #expect(imported.effectiveGridSpacing == config.effectiveGridSpacing)

        #expect(imported.items.count == 2)
        // Config equality up to placeholder substitution: the app bundle lives
        // inside the DMG and imports as an unfilled placeholder with its name and
        // position preserved but no source.
        let app = try #require(imported.items.first { $0.kind == .app })
        #expect(app.label == "Tiny.app")
        #expect(app.position == CGPoint(x: 150, y: 210))
        #expect(app.sourcePath == nil)
        #expect(app.isPlaceholder == true)

        let symlink = try #require(imported.items.first { $0.kind == .applicationsSymlink })
        #expect(symlink.position == CGPoint(x: 450, y: 210))

        // The gradient and text layer bake into a single background image at
        // build time; import returns it as one image layer whose bytes match
        // the baked file (the same bytes copied to the DMG's `.background/`).
        #expect(imported.background.type == .image)
        let layer = try #require(imported.background.layers.first)
        let importedImage = try #require(result.assets[layer.imageName])
        let bakedImage = try Data(contentsOf: assetsDir.appending(path: "background.tiff"))
        #expect(importedImage == bakedImage)

        try assertNotMounted(image: outputDMG)
    }

    // MARK: - Third-Party DMG

    private nonisolated static let thirdPartyCandidates = [
        "CodeEdit.dmg",
        "SigmaOS.dmg",
        "ImHex 1.37.1 macOS arm64.dmg",
        "Refrax-latest.dmg",
    ]

    private nonisolated static var thirdPartyDMG: URL? {
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Downloads")
        return thirdPartyCandidates
            .map { downloads.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @Test(
        "Importing a third-party DMG yields a sensible document",
        .enabled(
            if: DMGImporterTests.thirdPartyDMG != nil,
            "No third-party DMG fixture found in ~/Downloads — skipping"
        ),
        .timeLimit(.minutes(2))
    )
    func thirdPartyImport() async throws {
        let dmg = try #require(Self.thirdPartyDMG)
        let result = try await DMGImporter.importLayout(of: dmg)
        let imported = result.configuration

        #expect(!imported.items.isEmpty)
        #expect(imported.items.contains { $0.kind == .app })
        #expect(imported.items.contains { $0.kind == .applicationsSymlink })
        for item in imported.items {
            #expect(item.position.x > -100 && item.position.x < 4_000)
            #expect(item.position.y > -100 && item.position.y < 4_000)
        }
        #expect(imported.window.width >= 320)
        #expect(imported.window.height >= 200)

        // Every known fixture is a styled DMG with an image background.
        #expect(imported.background.type == .image)
        #expect(imported.background.layers.count == 1)
        if let layer = imported.background.layers.first {
            #expect(result.assets[layer.imageName]?.isEmpty == false)
        }

        try assertNotMounted(image: dmg)
    }

    // MARK: - Defaults Without .DS_Store

    @Test(
        "A DMG with no .DS_Store imports with default layout",
        .timeLimit(.minutes(2))
    )
    func importWithoutDSStore() async throws {
        let dmg = try await makeBareDMG(volumeName: "BareVolume", fileName: "Readme.txt")
        defer { cleanup(dmg) }

        let result = try await DMGImporter.importLayout(of: dmg)
        let imported = result.configuration

        #expect(imported.volumeName == "BareVolume")
        #expect(imported.window == WindowConfiguration())
        #expect(imported.background.type == .none)

        #expect(imported.items.count == 1)
        let item = try #require(imported.items.first)
        #expect(item.label == "Readme.txt")
        #expect(item.kind == .file)
        #expect(item.sourcePath == nil)
        #expect(item.position == CGPoint(x: 330, y: 200))

        try assertNotMounted(image: dmg)
    }

    // MARK: - Error Paths

    @Test("A corrupt file fails with a clean error and no stray mounts")
    func corruptImageFails() async throws {
        let bogus = tempPath("corrupt", extension: "dmg")
        try Data("this is not a disk image".utf8).write(to: bogus)
        defer { cleanup(bogus) }

        await #expect(throws: DMGImporter.ImportError.self) {
            _ = try await DMGImporter.importLayout(of: bogus)
        }

        try assertNotMounted(image: bogus)
    }

    // MARK: - Fixtures

    private struct TinyAppFixture {
        let root: URL
        let app: URL
    }

    /// Builds a minimal but valid `.app` bundle for copy-into-DMG tests.
    private func makeTinyApp() throws -> TinyAppFixture {
        let root = tempDir("tiny-app")
        let macOS = root.appending(path: "Tiny.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho hi".utf8).write(to: macOS.appending(path: "Tiny"))

        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>Tiny</string>
        <key>CFBundleIdentifier</key><string>test.tiny</string>
        </dict></plist>
        """.utf8).write(to: root.appending(path: "Tiny.app/Contents/Info.plist"))

        return TinyAppFixture(root: root, app: root.appending(path: "Tiny.app"))
    }

    /// Creates a writable DMG containing a single file and no `.DS_Store`.
    private func makeBareDMG(volumeName: String, fileName: String) async throws -> URL {
        let dmg = try await DMGBuilder.createWritableImage(
            volumeName: volumeName,
            size: "16m",
            filesystem: .hfsPlus
        )
        let mountPoint = try await DMGBuilder.attach(dmg)
        do {
            try Data("hello".utf8).write(to: mountPoint.appending(path: fileName))
            try await DMGBuilder.detach(mountPoint)
        } catch {
            try? await DMGBuilder.detach(mountPoint)
            throw error
        }
        try? FileManager.default.removeItem(at: mountPoint)
        return dmg
    }

    // MARK: - Helpers

    /// Asserts the given disk image is no longer attached.
    ///
    /// Deliberately scoped to this test's own image rather than to every
    /// `rilmazafone-import` mount: other suites legitimately run imports in
    /// parallel, so a global assertion races against their transient mounts.
    private func assertNotMounted(image: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let info = String(data: data, encoding: .utf8) ?? ""
        #expect(!info.contains(image.path))
    }

    private func tempDir(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "rilmazafone-test-\(name)-\(UUID().uuidString)")
    }

    private func tempPath(_ name: String, extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "rilmazafone-test-\(name)-\(UUID().uuidString).\(ext)")
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
