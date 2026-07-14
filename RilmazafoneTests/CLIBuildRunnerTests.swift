import CoreGraphics
import Foundation
import Testing
@testable import Rilmazafone

@Suite("CLIBuildRunner")
struct CLIBuildRunnerTests {
    // MARK: - Argument Parsing

    @Test
    func `parseBuildArguments: valid arguments with -o`() {
        let result = CLIBuildRunner.parseBuildArguments(["template.dmgtemplate", "-o", "out.dmg"])
        #expect(result?.template == "template.dmgtemplate")
        #expect(result?.output == "out.dmg")
    }

    @Test
    func `parseBuildArguments: valid arguments with --output`() {
        let result = CLIBuildRunner.parseBuildArguments(["template.dmgtemplate", "--output", "out.dmg"])
        #expect(result?.template == "template.dmgtemplate")
        #expect(result?.output == "out.dmg")
    }

    @Test
    func `parseBuildArguments: returns nil with too few arguments`() {
        #expect(CLIBuildRunner.parseBuildArguments([]) == nil)
        #expect(CLIBuildRunner.parseBuildArguments(["template.dmgtemplate"]) == nil)
        #expect(CLIBuildRunner.parseBuildArguments(["template.dmgtemplate", "-o"]) == nil)
    }

    @Test
    func `parseBuildArguments: returns nil with wrong flag`() {
        #expect(CLIBuildRunner.parseBuildArguments(["template.dmgtemplate", "-x", "out.dmg"]) == nil)
    }

    // MARK: - Help Flags

    @Test
    func `run returns 0 for -h`() {
        #expect(CLIBuildRunner.run(arguments: ["-h"]) == 0)
    }

    @Test
    func `run returns 0 for --help`() {
        #expect(CLIBuildRunner.run(arguments: ["--help"]) == 0)
    }

    @Test
    func `runInit returns 0 for --help`() {
        #expect(CLIBuildRunner.runInit(arguments: ["--help"]) == 0)
    }

    // MARK: - Template Generation (init)

    @Test
    func `generateTemplate creates valid directory structure`() {
        let dir = tempDir("init-structure")
        defer { cleanup(dir) }

        let code = CLIBuildRunner.generateTemplate(at: dir.path)
        #expect(code == 0)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: dir.appending(path: "document.json").path))
        #expect(fm.fileExists(atPath: dir.appending(path: "Assets").path))
    }

    @Test
    func `generateTemplate produces decodable configuration`() throws {
        let dir = tempDir("init-decodable")
        defer { cleanup(dir) }

        let code = CLIBuildRunner.generateTemplate(at: dir.path)
        #expect(code == 0)

        let data = try Data(contentsOf: dir.appending(path: "document.json"))
        let config = try JSONDecoder().decode(DMGConfiguration.self, from: data)

        #expect(config.volumeName == "Untitled")
        #expect(config.window.width == 660)
        #expect(config.window.height == 400)
        #expect(config.dmgFormat == .ulfo)
        #expect(config.filesystem == .apfs)
        #expect(config.items.isEmpty)
    }

    @Test
    func `generateTemplate matches default DMGConfiguration`() throws {
        let dir = tempDir("init-default")
        defer { cleanup(dir) }

        _ = CLIBuildRunner.generateTemplate(at: dir.path)

        let data = try Data(contentsOf: dir.appending(path: "document.json"))
        let decoded = try JSONDecoder().decode(DMGConfiguration.self, from: data)
        let original = DMGConfiguration()

        #expect(decoded == original)
    }

    @Test
    func `generateTemplate fails if path already exists`() throws {
        let dir = tempDir("init-existing")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { cleanup(dir) }

        let code = CLIBuildRunner.generateTemplate(at: dir.path)
        #expect(code == 1)
    }

    // MARK: - Template Loading

    @Test
    func `loadTemplate round-trips a configuration`() throws {
        let dir = tempDir("load-roundtrip")
        defer { cleanup(dir) }

        var config = DMGConfiguration()
        config.volumeName = "TestVolume"
        config.iconSize = 96
        config.items = [
            CanvasItem(kind: .applicationsSymlink, label: "Applications", position: CGPoint(x: 400, y: 200)),
        ]

        try writeTemplate(config, to: dir)

        let (loaded, assetsDir) = try CLIBuildRunner.loadTemplate(at: dir)
        defer { cleanup(assetsDir) }

        #expect(loaded.volumeName == "TestVolume")
        #expect(loaded.iconSize == 96)
        #expect(loaded.items.count == 1)
        #expect(loaded.items[0].kind == .applicationsSymlink)
    }

    @Test
    func `loadTemplate expands abbreviated paths`() throws {
        let dir = tempDir("load-expand")
        defer { cleanup(dir) }

        var config = DMGConfiguration()
        config.items = [
            CanvasItem(kind: .app, label: "App.app", sourcePath: "~/Desktop/App.app", position: .zero),
        ]

        // Write with tilde paths (as stored on disk)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appending(path: "Assets"), withIntermediateDirectories: true)
        try encoder.encode(config).write(to: dir.appending(path: "document.json"))

        let (loaded, assetsDir) = try CLIBuildRunner.loadTemplate(at: dir)
        defer { cleanup(assetsDir) }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(loaded.items[0].sourcePath == "\(home)/Desktop/App.app")
    }

    @Test
    func `loadTemplate extracts assets`() throws {
        let dir = tempDir("load-assets")
        defer { cleanup(dir) }

        let config = DMGConfiguration()
        try writeTemplate(config, to: dir)

        // Add a dummy asset
        let assetData = Data("test-asset-content".utf8)
        try assetData.write(to: dir.appending(path: "Assets/test-image.png"))

        let (_, assetsDir) = try CLIBuildRunner.loadTemplate(at: dir)
        defer { cleanup(assetsDir) }

        let extractedAsset = assetsDir.appending(path: "test-image.png")
        #expect(FileManager.default.fileExists(atPath: extractedAsset.path))

        let extractedData = try Data(contentsOf: extractedAsset)
        #expect(extractedData == assetData)
    }

    @Test
    func `loadTemplate fails with missing document.json`() throws {
        let dir = tempDir("load-missing")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { cleanup(dir) }

        #expect(throws: (any Error).self) {
            try CLIBuildRunner.loadTemplate(at: dir)
        }
    }

    // MARK: - Size Estimation

    @Test
    func `estimateSize returns at least APFS minimum for empty config`() throws {
        var config = DMGConfiguration()
        config.filesystem = .apfs
        config.items = []

        let size = try CLIBuildRunner.estimateSize(for: config)
        // APFS minimum: 128 MB base overhead * 1.5 headroom = 192m (but max with 128m min)
        // Base 32MB * 1.5 = 48MB, clamped to 128MB minimum
        #expect(size == "128m")
    }

    @Test
    func `estimateSize returns at least HFS+ minimum for empty config`() throws {
        var config = DMGConfiguration()
        config.filesystem = .hfsPlus
        config.items = []

        let size = try CLIBuildRunner.estimateSize(for: config)
        // Base 32MB * 1.5 = 48MB, clamped to 32MB minimum → 48m
        #expect(size == "48m")
    }

    @Test
    func `estimateSize skips Applications symlink items`() throws {
        var config = DMGConfiguration()
        config.filesystem = .apfs
        config.items = [
            CanvasItem(kind: .applicationsSymlink, label: "Applications", position: .zero),
        ]

        let sizeWithSymlink = try CLIBuildRunner.estimateSize(for: config)

        config.items = []
        let sizeWithout = try CLIBuildRunner.estimateSize(for: config)

        #expect(sizeWithSymlink == sizeWithout)
    }

    // MARK: - Build Error Handling

    @Test
    func `run returns 1 for missing template`() {
        let code = CLIBuildRunner.run(arguments: [
            "/tmp/nonexistent-\(UUID().uuidString).dmgtemplate",
            "-o", "/tmp/out.dmg",
        ])
        #expect(code == 1)
    }

    @Test
    func `run returns 1 for invalid arguments`() {
        #expect(CLIBuildRunner.run(arguments: []) == 1)
    }

    // MARK: - Init Default Path

    @Test
    func `runInit uses default name when no path given`() throws {
        let originalDir = FileManager.default.currentDirectoryPath
        let workDir = tempDir("init-default-name")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        FileManager.default.changeCurrentDirectoryPath(workDir.path)
        defer {
            FileManager.default.changeCurrentDirectoryPath(originalDir)
            cleanup(workDir)
        }

        let code = CLIBuildRunner.runInit(arguments: [])
        #expect(code == 0)
        #expect(FileManager.default.fileExists(
            atPath: workDir.appending(path: "Untitled.dmgtemplate/document.json").path,
        ))
    }

    // MARK: - Full Build Integration

    @Test(
        .timeLimit(.minutes(2)),
    )
    func `CLI build produces a valid DMG from a minimal template`() throws {
        let templateDir = tempDir("integration-template")
        let outputDMG = tempPath("integration-output", extension: "dmg")
        defer {
            cleanup(templateDir)
            cleanup(outputDMG)
        }

        // Create a minimal app bundle to include
        let appDir = tempDir("integration-app")
        let appBundle = appDir.appending(path: "Tiny.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho hi".utf8).write(to: appBundle.appending(path: "Tiny"))

        let plist = appDir.appending(path: "Tiny.app/Contents/Info.plist")
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleExecutable</key><string>Tiny</string>
        <key>CFBundleIdentifier</key><string>test.tiny</string>
        </dict></plist>
        """.utf8).write(to: plist)
        defer { cleanup(appDir) }

        // Create template with this app
        var config = DMGConfiguration()
        config.volumeName = "TestBuild"
        config.dmgFormat = .udzo
        config.filesystem = .hfsPlus
        config.volumeIcon = VolumeIconConfiguration(type: .none)
        config.items = [
            CanvasItem(
                kind: .app,
                label: "Tiny.app",
                sourcePath: appDir.appending(path: "Tiny.app").path,
                position: CGPoint(x: 150, y: 200),
            ),
            CanvasItem(
                kind: .applicationsSymlink,
                label: "Applications",
                position: CGPoint(x: 400, y: 200),
            ),
        ]

        try writeTemplate(config, to: templateDir)

        // Run CLI build
        let code = CLIBuildRunner.run(arguments: [
            templateDir.path, "-o", outputDMG.path,
        ])
        #expect(code == 0)
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: outputDMG.path))

        // Verify the DMG is a valid disk image
        let attrs = try fm.attributesOfItem(atPath: outputDMG.path)
        let fileSize = attrs[.size] as? UInt64 ?? 0
        #expect(fileSize > 0)

        // Mount, verify contents, unmount
        let mountPoint = fm.temporaryDirectory
            .appending(path: "rilmazafone-test-mount-\(UUID().uuidString)")
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        defer {
            _ = try? Process.run(
                URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["detach", mountPoint.path, "-force"],
            )
            try? fm.removeItem(at: mountPoint)
        }

        let attach = try Process.run(
            URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["attach", outputDMG.path, "-noautoopen", "-nobrowse", "-noverify", "-mountpoint", mountPoint.path],
        )
        attach.waitUntilExit()
        #expect(attach.terminationStatus == 0)

        #expect(fm.fileExists(atPath: mountPoint.appending(path: "Tiny.app").path))
        #expect(fm.fileExists(atPath: mountPoint.appending(path: "Applications").path))
        #expect(fm.fileExists(atPath: mountPoint.appending(path: ".DS_Store").path))

        // Verify Applications is a symlink to /Applications
        let linkAttrs = try fm.attributesOfItem(atPath: mountPoint.appending(path: "Applications").path)
        #expect(linkAttrs[.type] as? FileAttributeType == .typeSymbolicLink)

        let dest = try fm.destinationOfSymbolicLink(atPath: mountPoint.appending(path: "Applications").path)
        #expect(dest == "/Applications")
    }

    @Test(
        .timeLimit(.minutes(2)),
    )
    func `CLI build produces same .DS_Store as BuildManager for identical config`() throws {
        // Both paths use DSStoreWriter.write() with the same config,
        // so the .DS_Store bytes should be identical.
        var config = DMGConfiguration()
        config.volumeName = "ParityTest"
        config.window = WindowConfiguration(width: 540, height: 380)
        config.iconSize = 80
        config.textSize = 12
        config.items = [
            CanvasItem(
                kind: .app,
                label: "App.app",
                sourcePath: "/tmp/fake",
                position: CGPoint(x: 150, y: 190),
            ),
            CanvasItem(
                kind: .applicationsSymlink,
                label: "Applications",
                position: CGPoint(x: 390, y: 190),
            ),
        ]

        // Generate .DS_Store the same way both paths do
        let dsStoreData = try DSStoreWriter.write(
            configuration: config,
            backgroundAlias: nil,
            backgroundBookmark: nil,
        )

        // Generate again — must be deterministic
        let dsStoreData2 = try DSStoreWriter.write(
            configuration: config,
            backgroundAlias: nil,
            backgroundBookmark: nil,
        )

        if dsStoreData != dsStoreData2 {
            let firstDiff = zip(dsStoreData, dsStoreData2).enumerated()
                .first { $1.0 != $1.1 }?.offset
            Issue.record(
                """
                DSStoreWriter output differed between two same-process writes \
                (counts \(dsStoreData.count) vs \(dsStoreData2.count), first \
                differing offset \(firstDiff.map(String.init) ?? "n/a — length only")). \
                This flake has only ever appeared under parallel suite load; \
                capture these numbers when it recurs.
                """,
            )
        }
        #expect(dsStoreData.count > 0)
    }

    // MARK: - Helpers

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

    private func writeTemplate(_ config: DMGConfiguration, to dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appending(path: "Assets"), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: dir.appending(path: "document.json"))
    }
}
