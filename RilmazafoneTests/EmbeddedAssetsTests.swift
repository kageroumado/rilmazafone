import CoreGraphics
import Foundation
import Testing
@testable import Rilmazafone

/// Unit coverage for embedded item payloads: cap enforcement, folder archive
/// round-trips, build-time materialization, and the template embedding pass.
@Suite("Embedded assets")
struct EmbeddedAssetsTests {
    // MARK: - Helpers

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "embedded-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    // MARK: - Naming

    @Test("Asset names are unique per item and keep the file extension")
    func assetNaming() {
        let id = UUID()
        let fileName = EmbeddedAssets.assetName(itemID: id, label: "Read Me.pdf", kind: .file)
        #expect(fileName.hasSuffix("Read Me.pdf"))
        #expect(fileName.contains(id.uuidString.prefix(8)))

        let folderName = EmbeddedAssets.assetName(itemID: id, label: "Docs", kind: .folder)
        #expect(folderName.hasSuffix(".aar"))

        let hostile = EmbeddedAssets.assetName(itemID: id, label: "a/b:c", kind: .file)
        #expect(!hostile.contains("/"))
        #expect(!hostile.contains(":"))
    }

    // MARK: - File Payloads

    @Test("File payload round-trips under the cap")
    func filePayloadUnderCap() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appending(path: "readme.md")
        try write("# Hello", to: source)

        let payload = try #require(try EmbeddedAssets.payload(for: source, kind: .file))
        #expect(payload == Data("# Hello".utf8))
    }

    @Test("File payload is nil over the cap")
    func filePayloadOverCap() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appending(path: "big.bin")
        let oversized = Data(count: EmbeddedAssets.sizeCap + 1)
        try oversized.write(to: source)

        #expect(try EmbeddedAssets.payload(for: source, kind: .file) == nil)
    }

    @Test("App kinds never produce a payload")
    func appPayloadIsNil() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try EmbeddedAssets.payload(for: dir, kind: .app) == nil)
    }

    // MARK: - Folder Payloads

    @Test("Folder payload archives and extracts a directory tree")
    func folderPayloadRoundTrip() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appending(path: "Docs")
        let nested = source.appending(path: "guides")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try write("top", to: source.appending(path: "top.txt"))
        try write("nested", to: nested.appending(path: "nested.txt"))

        let payload = try #require(try EmbeddedAssets.payload(for: source, kind: .folder))

        let archive = dir.appending(path: "payload.aar")
        try payload.write(to: archive)
        let extracted = dir.appending(path: "extracted")
        try EmbeddedAssets.extractArchive(at: archive, to: extracted)

        let top = try String(contentsOf: extracted.appending(path: "top.txt"), encoding: .utf8)
        let deep = try String(
            contentsOf: extracted.appending(path: "guides/nested.txt"), encoding: .utf8
        )
        #expect(top == "top")
        #expect(deep == "nested")
    }

    @Test("Folder payload is nil when contents exceed the cap")
    func folderPayloadOverCap() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appending(path: "Big")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let half = Data(count: EmbeddedAssets.sizeCap / 2 + 1)
        try half.write(to: source.appending(path: "a.bin"))
        try half.write(to: source.appending(path: "b.bin"))

        #expect(try EmbeddedAssets.payload(for: source, kind: .folder) == nil)
    }

    // MARK: - Materialization

    @Test("Materialize resolves file payloads and extracts folder payloads")
    func materializeItems() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let assetsDir = dir.appending(path: "Assets")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        let staging = dir.appending(path: "Staging")

        var fileItem = CanvasItem(kind: .file, label: "readme.md", position: .zero)
        let fileAsset = EmbeddedAssets.assetName(
            itemID: fileItem.id, label: fileItem.label, kind: .file
        )
        fileItem.assetName = fileAsset
        try write("payload", to: assetsDir.appending(path: fileAsset))

        let folderSource = dir.appending(path: "Docs")
        try FileManager.default.createDirectory(at: folderSource, withIntermediateDirectories: true)
        try write("inside", to: folderSource.appending(path: "inside.txt"))
        var folderItem = CanvasItem(kind: .folder, label: "Docs", position: .zero)
        let folderAsset = EmbeddedAssets.assetName(
            itemID: folderItem.id, label: folderItem.label, kind: .folder
        )
        folderItem.assetName = folderAsset
        let folderPayload = try #require(try EmbeddedAssets.payload(for: folderSource, kind: .folder))
        try folderPayload.write(to: assetsDir.appending(path: folderAsset))

        let external = CanvasItem(
            kind: .file, label: "ext.txt", sourcePath: "/tmp/ext.txt", position: .zero
        )

        let materialized = try EmbeddedAssets.materialize(
            items: [fileItem, folderItem, external],
            assetsDirectory: assetsDir,
            stagingDirectory: staging
        )

        let file = materialized[0]
        #expect(file.assetName == nil)
        let filePath = try #require(file.sourcePath)
        #expect(try String(contentsOf: URL(fileURLWithPath: filePath), encoding: .utf8) == "payload")

        let folder = materialized[1]
        #expect(folder.assetName == nil)
        let folderPath = try #require(folder.sourcePath)
        let inside = try String(
            contentsOf: URL(fileURLWithPath: folderPath).appending(path: "inside.txt"),
            encoding: .utf8
        )
        #expect(inside == "inside")

        #expect(materialized[2] == external)
    }

    @Test("Materialize throws for a missing payload")
    func materializeMissingPayload() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var item = CanvasItem(kind: .file, label: "gone.txt", position: .zero)
        item.assetName = "item-00000000-gone.txt"

        #expect(throws: EmbeddedAssets.EmbedError.self) {
            _ = try EmbeddedAssets.materialize(
                items: [item],
                assetsDirectory: dir,
                stagingDirectory: dir.appending(path: "staging")
            )
        }
    }

    // MARK: - Template Embedding Pass

    @Test("embedItems embeds a reachable small file and strips its reference")
    func embedItemsSmallFile() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appending(path: "License.txt")
        try write("MIT", to: source)
        let item = CanvasItem(
            kind: .file, label: "License.txt",
            sourcePath: source.path, position: CGPoint(x: 40, y: 60)
        )

        let result = TemplateSnapshot.embedItems([item], documentURL: nil)
        let embedded = try #require(result.items.first)
        let assetName = try #require(embedded.assetName)
        #expect(embedded.sourcePath == nil)
        #expect(embedded.sourceBookmark == nil)
        #expect(embedded.isPlaceholder == false)
        #expect(embedded.position == item.position)
        #expect(result.payloads[assetName] == Data("MIT".utf8))
    }

    @Test("embedItems converts over-cap and unreachable sources to typed slots")
    func embedItemsPlaceholders() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bigSource = dir.appending(path: "huge.bin")
        try Data(count: EmbeddedAssets.sizeCap + 1).write(to: bigSource)
        var big = CanvasItem(
            kind: .file, label: "huge.bin",
            sourcePath: bigSource.path, position: CGPoint(x: 10, y: 20)
        )
        big.background = ItemBackground()

        let missing = CanvasItem(
            kind: .folder, label: "Ghost",
            sourcePath: dir.appending(path: "ghost").path, position: .zero
        )

        let result = TemplateSnapshot.embedItems([big, missing], documentURL: nil)

        let bigSlot = result.items[0]
        #expect(bigSlot.isPlaceholder)
        #expect(bigSlot.kind == .file)
        #expect(bigSlot.label == "huge.bin")
        #expect(bigSlot.position == big.position)
        #expect(bigSlot.background == big.background)
        #expect(bigSlot.sourcePath == nil)

        let missingSlot = result.items[1]
        #expect(missingSlot.isPlaceholder)
        #expect(missingSlot.kind == .folder)
        #expect(result.payloads.isEmpty)
    }

    @Test("embedItems passes through symlinks, placeholders, and embedded items")
    func embedItemsPassThrough() {
        let symlink = CanvasItem(
            kind: .file, label: "link", sourcePath: "/tmp/target",
            position: .zero, linkType: .symlink
        )
        let slot = CanvasItem.filePlaceholder(position: .zero)
        var alreadyEmbedded = CanvasItem(kind: .file, label: "done.txt", position: .zero)
        alreadyEmbedded.assetName = "item-12345678-done.txt"
        let applications = CanvasItem(
            kind: .applicationsSymlink, label: "Applications", position: .zero
        )

        let items = [symlink, slot, alreadyEmbedded, applications]
        let result = TemplateSnapshot.embedItems(items, documentURL: nil)
        #expect(result.items == items)
        #expect(result.payloads.isEmpty)
    }

    @Test("requiresSource is false for embedded items")
    func embeddedItemsRequireNoSource() {
        var item = CanvasItem(kind: .file, label: "readme.md", position: .zero)
        item.assetName = "item-12345678-readme.md"
        #expect(!item.requiresSource)
        #expect(item.isEmbedded)
    }

    @Test("CanvasItem decoding tolerates documents without assetName")
    func decodingBackwardCompatible() throws {
        let legacy = CanvasItem(
            kind: .file, label: "old.txt", sourcePath: "/tmp/old.txt", position: .zero
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(CanvasItem.self, from: data)
        #expect(decoded.assetName == nil)
        #expect(decoded == legacy)
    }
}
