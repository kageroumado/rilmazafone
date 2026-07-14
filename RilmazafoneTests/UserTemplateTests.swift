import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Rilmazafone

// MARK: - Snapshot Conversion

@Suite("Template Snapshot")
struct TemplateSnapshotTests {
    @Test("A filled app item becomes a standard placeholder at the same position")
    func appItemBecomesPlaceholder() throws {
        let panel = ItemBackground(opacity: 0.5, cornerRadius: 12)
        var configuration = DMGConfiguration()
        configuration.items = [
            CanvasItem(
                kind: .app,
                label: "Refrax.app",
                sourcePath: "/Applications/Refrax.app",
                sourceBookmark: Data([0x01, 0x02, 0x03]),
                position: CGPoint(x: 150, y: 210),
                background: panel
            ),
            CanvasItem(
                kind: .applicationsSymlink,
                label: "Applications",
                position: CGPoint(x: 450, y: 210)
            ),
        ]
        configuration.codeSign = CodeSignConfiguration(
            enabled: true, identity: "Developer ID Application: Someone (TEAM123)"
        )

        let template = TemplateSnapshot.templateConfiguration(from: configuration)

        #expect(template.items.count == 2)
        let placeholder = try #require(template.items.first { $0.kind == .app })
        #expect(placeholder.isPlaceholder)
        #expect(placeholder.label == CanvasItem.placeholderLabel)
        #expect(placeholder.position == CGPoint(x: 150, y: 210))
        #expect(placeholder.sourcePath == nil)
        #expect(placeholder.sourceBookmark == nil)
        #expect(placeholder.background == panel)

        #expect(template.codeSign == CodeSignConfiguration())
        #expect(template.items[1] == configuration.items[1])
    }

    @Test("Non-app items, layers, and window settings pass through unchanged")
    func designPassesThrough() {
        var configuration = DMGConfiguration()
        configuration.window = WindowConfiguration(width: 720, height: 460)
        configuration.iconSize = 96
        configuration.background.type = .image
        configuration.background.layers = [
            BackgroundLayer(
                id: UUID(),
                imageName: "bg.png",
                label: "bg.png",
                position: CGPoint(x: 360, y: 230)
            ),
        ]
        configuration.textLayers = [
            TextLayerConfiguration(text: "Drag to install", position: CGPoint(x: 360, y: 60)),
        ]
        configuration.items = [
            CanvasItem(
                kind: .folder,
                label: "Extras",
                sourcePath: "~/Extras",
                position: CGPoint(x: 200, y: 300)
            ),
        ]

        let template = TemplateSnapshot.templateConfiguration(from: configuration)

        #expect(template.window == configuration.window)
        #expect(template.iconSize == configuration.iconSize)
        #expect(template.background == configuration.background)
        #expect(template.textLayers == configuration.textLayers)
        #expect(template.items == configuration.items)
    }

    @Test("Referenced asset names cover background layers and the volume icon")
    func referencedAssetNames() {
        var configuration = DMGConfiguration()
        configuration.background.layers = [
            BackgroundLayer(id: UUID(), imageName: "bg-a.png", label: "a", position: .zero),
            BackgroundLayer(id: UUID(), imageName: "bg-b.png", label: "b", position: .zero),
        ]
        configuration.volumeIcon = VolumeIconConfiguration(
            type: .custom, sourceIconName: "volume-icon.icns"
        )

        let names = TemplateSnapshot.referencedAssetNames(in: configuration)
        #expect(names == ["bg-a.png", "bg-b.png", "volume-icon.icns"])
    }

    @MainActor
    @Test("A document snapshot converts the app item and copies only referenced assets")
    func documentSnapshot() throws {
        let document = RilmazafoneDocument()
        let layerID = UUID()
        document.configuration.background.type = .image
        document.configuration.background.layers = [
            BackgroundLayer(
                id: layerID, imageName: "bg.png", label: "bg.png", position: CGPoint(x: 330, y: 200)
            ),
        ]
        document.configuration.items = [
            CanvasItem(
                kind: .app,
                label: "Tool.app",
                sourcePath: "/Applications/Tool.app",
                position: CGPoint(x: 180, y: 190)
            ),
        ]

        let backgroundData = Data([0x89, 0x50, 0x4E, 0x47])
        document.ensureAssetsWrapper()
        document.replaceAsset(named: "bg.png", with: backgroundData)
        document.replaceAsset(named: "stale.png", with: Data([0xFF]))

        let snapshot = document.templateSnapshot()

        let placeholder = try #require(snapshot.configuration.items.first)
        #expect(placeholder.isPlaceholder)
        #expect(placeholder.label == CanvasItem.placeholderLabel)
        #expect(placeholder.position == CGPoint(x: 180, y: 190))
        #expect(placeholder.sourcePath == nil)

        #expect(snapshot.assets == ["bg.png": backgroundData])
    }
}

// MARK: - Saving User Templates

@MainActor
@Suite("User template saving")
struct UserTemplateSavingTests {
    private func makeUserDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "UserTemplateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeRegistry(userDirectory: URL) -> TemplateRegistry {
        TemplateRegistry(
            bundledDirectory: nil,
            userDirectory: userDirectory,
            watchesUserDirectory: false,
            prewarmsThumbnails: false
        )
    }

    @Test("A DMG import result saves as a placeholder template without runtime icons")
    func fromDMGResultSavesCleanTemplate() throws {
        let userDir = try makeUserDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }
        let registry = makeRegistry(userDirectory: userDir)

        var configuration = DMGConfiguration()
        configuration.volumeName = "Refrax"
        let appItem = CanvasItem.appPlaceholder(
            label: "Refrax.app", position: CGPoint(x: 140, y: 200)
        )
        configuration.items = [
            appItem,
            CanvasItem(
                kind: .applicationsSymlink,
                label: "Applications",
                position: CGPoint(x: 460, y: 200)
            ),
        ]
        configuration.background.type = .image
        configuration.background.layers = [
            BackgroundLayer(
                id: UUID(), imageName: "bg-import.png", label: "background.png",
                position: CGPoint(x: 300, y: 200)
            ),
        ]
        let backgroundData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D])
        let result = DMGImporter.Result(
            configuration: configuration,
            assets: ["bg-import.png": backgroundData],
            itemIcons: [appItem.id: Data([0x69, 0x63, 0x6E, 0x73])]
        )

        let entry = try registry.saveUserTemplate(
            named: "From DMG",
            configuration: TemplateSnapshot.templateConfiguration(from: result.configuration),
            assets: result.assets
        )

        let reloaded = try TemplateInstantiator.configuration(ofTemplateAt: entry.url)
        let placeholder = try #require(reloaded.items.first { $0.kind == .app })
        #expect(placeholder.isPlaceholder)
        #expect(placeholder.label == CanvasItem.placeholderLabel)
        #expect(placeholder.position == CGPoint(x: 140, y: 200))

        // Assets carry exactly the design payloads — no harvested app icons.
        #expect(TemplateInstantiator.assets(ofTemplateAt: entry.url) == result.assets)
        let packageContents = try FileManager.default
            .contentsOfDirectory(atPath: entry.url.path).sorted()
        #expect(packageContents == ["Assets", "document.json"])
    }

    @Test("Save round-trip: a new document from the saved template reproduces the design")
    func saveRoundTripReproducesDesign() throws {
        let userDir = try makeUserDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }
        let registry = makeRegistry(userDirectory: userDir)

        var configuration = DMGConfiguration()
        configuration.window = WindowConfiguration(width: 700, height: 420)
        configuration.background.type = .image
        configuration.background.layers = [
            BackgroundLayer(
                id: UUID(), imageName: "bg.png", label: "bg.png", position: CGPoint(x: 350, y: 210)
            ),
        ]
        configuration.items = [
            CanvasItem(
                kind: .app,
                label: "Filled.app",
                sourcePath: "/Applications/Filled.app",
                position: CGPoint(x: 175, y: 220)
            ),
            CanvasItem(
                kind: .applicationsSymlink,
                label: "Applications",
                position: CGPoint(x: 525, y: 220)
            ),
        ]
        let template = TemplateSnapshot.templateConfiguration(from: configuration)
        let assets = ["bg.png": Data([0x01, 0x02, 0x03, 0x04])]

        let entry = try registry.saveUserTemplate(
            named: "Round Trip", configuration: template, assets: assets
        )
        #expect(registry.user.contains(entry))

        let result = try TemplateInstantiator.instantiate(templateAt: entry.url)
        #expect(result.configuration.items == template.items)
        #expect(result.configuration.window == template.window)
        #expect(result.configuration.background == template.background)
        #expect(result.assets == assets)

        let placeholder = try #require(result.configuration.items.first { $0.kind == .app })
        #expect(placeholder.isPlaceholder)
        #expect(placeholder.sourcePath == nil)
        #expect(placeholder.position == CGPoint(x: 175, y: 220))
    }

    @Test("Renaming a user template preserves its assets")
    func renamePreservesAssets() throws {
        let userDir = try makeUserDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }
        let registry = makeRegistry(userDirectory: userDir)

        let assets = ["bg.png": Data([0x0A, 0x0B])]
        let original = try registry.saveUserTemplate(
            named: "Old Name", configuration: DMGConfiguration(), assets: assets
        )

        let renamed = try registry.renameUserTemplate(original, to: "New Name")

        #expect(renamed.name == "New Name")
        #expect(TemplateInstantiator.assets(ofTemplateAt: renamed.url) == assets)
        #expect(!FileManager.default.fileExists(atPath: original.url.path))
    }

    @Test("Deleting a saved template removes the package without error")
    func deleteRemovesPackage() throws {
        let userDir = try makeUserDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }
        let registry = makeRegistry(userDirectory: userDir)

        let entry = try registry.saveUserTemplate(
            named: "Trashed", configuration: DMGConfiguration(), assets: ["bg.png": Data([0x01])]
        )

        try registry.deleteUserTemplate(entry)

        #expect(!FileManager.default.fileExists(atPath: entry.url.path))
        #expect(registry.user.isEmpty)
    }
}

// MARK: - Real-DMG Acceptance

/// Headless version of the 3.4 acceptance check: a template made from a real
/// styled DMG, filled with a system app, builds a DMG whose imported layout
/// matches the template — positions, window, and a background whose on-volume
/// bytes equal the deterministic composite render of the template's asset.
@MainActor
@Suite("Template from DMG acceptance")
struct TemplateFromDMGAcceptanceTests {
    private nonisolated static let styledDMGCandidates = [
        "Refrax.dmg",
        "Refrax-latest.dmg",
        "SigmaOS.dmg",
        "CodeEdit.dmg",
    ]

    private nonisolated static var styledDMG: URL? {
        let downloads = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Downloads")
        return styledDMGCandidates
            .map { downloads.appending(path: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private nonisolated static var systemApp: URL? {
        [
            "/System/Applications/Calculator.app",
            "/System/Applications/TextEdit.app",
        ]
        .map { URL(fileURLWithPath: $0) }
        .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @Test(
        "A template from a real styled DMG rebuilds to match the design",
        .enabled(
            if: TemplateFromDMGAcceptanceTests.styledDMG != nil
                && TemplateFromDMGAcceptanceTests.systemApp != nil,
            "No styled DMG fixture found in ~/Downloads — skipping"
        ),
        .timeLimit(.minutes(5))
    )
    func templateFromRealDMGRebuilds() async throws {
        let dmg = try #require(Self.styledDMG)
        let app = try #require(Self.systemApp)
        let fileManager = FileManager.default

        let imported = try await DMGImporter.importLayout(of: dmg)

        // Save the import as a user template in a private library.
        let userDir = fileManager.temporaryDirectory
            .appending(path: "TemplateAcceptance-\(UUID().uuidString)")
        try fileManager.createDirectory(at: userDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: userDir) }

        let registry = TemplateRegistry(
            bundledDirectory: nil,
            userDirectory: userDir,
            watchesUserDirectory: false,
            prewarmsThumbnails: false
        )
        let entry = try registry.saveUserTemplate(
            named: "Acceptance",
            configuration: TemplateSnapshot.templateConfiguration(from: imported.configuration),
            assets: imported.assets
        )

        // The template's assets are byte-identical to the imported originals.
        let templateAssets = TemplateInstantiator.assets(ofTemplateAt: entry.url)
        if let originalLayer = imported.configuration.background.layers.first {
            #expect(
                templateAssets[originalLayer.imageName]
                    == imported.assets[originalLayer.imageName]
            )
        }

        // Instantiate and fill the placeholder with a system app.
        var buildConfiguration = try TemplateInstantiator.instantiate(templateAt: entry.url)
            .configuration
        let placeholderIndex = try #require(
            buildConfiguration.items.firstIndex(where: { $0.isPlaceholder })
        )
        let placeholderPosition = buildConfiguration.items[placeholderIndex].position
        buildConfiguration.items[placeholderIndex].label = app.lastPathComponent
        buildConfiguration.items[placeholderIndex].sourcePath = app.path
        buildConfiguration.items[placeholderIndex].isPlaceholder = false
        // Real DMGs can carry extra copy items whose sources only existed
        // inside the original volume; drop them the way a user would relink
        // or remove before building.
        buildConfiguration.items.removeAll { $0.requiresSource && $0.sourcePath == nil }

        // Stage the template's assets and build.
        let assetsDir = fileManager.temporaryDirectory
            .appending(path: "TemplateAcceptance-assets-\(UUID().uuidString)")
        try fileManager.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: assetsDir) }
        for (filename, data) in templateAssets {
            try data.write(to: assetsDir.appending(path: filename))
        }

        let outputDMG = fileManager.temporaryDirectory
            .appending(path: "TemplateAcceptance-\(UUID().uuidString).dmg")
        defer { try? fileManager.removeItem(at: outputDMG) }

        try await DMGBuildPipeline.build(
            configuration: buildConfiguration,
            assetsDirectory: assetsDir,
            outputURL: outputDMG,
            progress: { _ in }
        )

        // Re-import the fresh build and compare against the template design.
        let rebuilt = try await DMGImporter.importLayout(of: outputDMG)

        #expect(rebuilt.configuration.window == buildConfiguration.window)
        #expect(rebuilt.configuration.iconSize == buildConfiguration.iconSize)

        let rebuiltApp = try #require(rebuilt.configuration.items.first { $0.kind == .app })
        #expect(rebuiltApp.position == placeholderPosition)
        for item in buildConfiguration.items where item.kind != .app {
            let match = rebuilt.configuration.items.first { $0.label == item.label }
            #expect(match?.position == item.position, "position of \(item.label)")
        }

        // The volume's background bytes are exactly the deterministic
        // composite render of the template's background asset (the pipeline
        // stages that render as background.tiff in the assets directory).
        #expect(rebuilt.configuration.background.type == .image)
        let rebuiltLayer = try #require(rebuilt.configuration.background.layers.first)
        let bakedBackground = try Data(
            contentsOf: assetsDir.appending(path: "background.tiff")
        )
        #expect(rebuilt.assets[rebuiltLayer.imageName] == bakedBackground)
    }
}
