import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Rilmazafone

@Suite("Source bookmarks & missing-source state")
struct SourceBookmarkTests {
    // MARK: - Helpers

    private func makeTempFile(named name: String = "source.txt") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "source-bookmark-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: name)
        try Data("payload".utf8).write(to: file)
        return file
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - Codable

    @Test
    func `CanvasItem with sourceBookmark survives JSON round-trip`() throws {
        let bookmark = Data([0x62, 0x6F, 0x6F, 0x6B, 0x00, 0xFF])
        let item = CanvasItem(
            kind: .app,
            label: "App.app",
            sourcePath: "/tmp/App.app",
            sourceBookmark: bookmark,
            position: CGPoint(x: 100, y: 200),
        )

        let encoded = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(CanvasItem.self, from: encoded)

        #expect(decoded == item)
        #expect(decoded.sourceBookmark == bookmark)
    }

    @Test
    func `CanvasItem without sourceBookmark decodes nil (legacy documents)`() throws {
        let json = Data("""
        {
            "kind": "app",
            "label": "App.app",
            "sourcePath": "/tmp/App.app",
            "position": [100, 200]
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(CanvasItem.self, from: json)

        #expect(decoded.sourceBookmark == nil)
        #expect(decoded.sourcePath == "/tmp/App.app")
    }

    @Test
    func `Configuration with bookmarked items survives JSON round-trip`() throws {
        var config = DMGConfiguration()
        config.items = [
            CanvasItem(
                kind: .file,
                label: "README.txt",
                sourcePath: "/tmp/README.txt",
                sourceBookmark: Data([1, 2, 3]),
                position: CGPoint(x: 50, y: 60),
            ),
            CanvasItem(
                kind: .applicationsSymlink,
                label: "Applications",
                position: CGPoint(x: 400, y: 60),
            ),
        ]

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(DMGConfiguration.self, from: encoded)

        #expect(decoded == config)
    }

    // MARK: - requiresSource

    @Test
    func `requiresSource: copy items need one, symlinks do not`() {
        let copyItem = CanvasItem(kind: .file, label: "F", position: .zero)
        #expect(copyItem.requiresSource)

        var symlinkItem = CanvasItem(kind: .file, label: "S", position: .zero)
        symlinkItem.linkType = .symlink
        #expect(!symlinkItem.requiresSource)

        let appsLink = CanvasItem(kind: .applicationsSymlink, label: "Applications", position: .zero)
        #expect(!appsLink.requiresSource)
    }

    // MARK: - GitHub-Build Fallbacks

    #if !APPSTORE
        @Test
        func `makeBookmark returns nil in the unsandboxed build`() throws {
            let file = try makeTempFile()
            defer { cleanup(file) }

            #expect(SourceAccess.makeBookmark(for: file, documentURL: nil) == nil)
            #expect(SourceAccess.makeBookmark(for: file, documentURL: URL(fileURLWithPath: "/tmp/doc")) == nil)
        }
    #endif

    @Test
    func `withScope passes the raw path URL through when no bookmark exists`() {
        let received = SourceAccess.withScope(
            bookmark: nil, path: "/tmp/some/file", documentURL: nil,
        ) { $0 }
        #expect(received?.path == "/tmp/some/file")

        let nilReceived = SourceAccess.withScope(
            bookmark: nil, path: nil, documentURL: nil,
        ) { $0 }
        #expect(nilReceived == nil)
    }

    // MARK: - Availability

    @Test
    func `isSourceAvailable reflects on-disk existence for copy items`() throws {
        let file = try makeTempFile()
        defer { cleanup(file) }

        let item = CanvasItem(kind: .file, label: "F", sourcePath: file.path, position: .zero)
        #expect(SourceAccess.isSourceAvailable(item: item, documentURL: nil))

        try FileManager.default.removeItem(at: file)
        #expect(!SourceAccess.isSourceAvailable(item: item, documentURL: nil))
    }

    @Test
    func `Symlink-type and Applications-symlink items are always available`() {
        var symlinkItem = CanvasItem(
            kind: .folder, label: "L", sourcePath: "/nonexistent/target", position: .zero,
        )
        symlinkItem.linkType = .symlink
        #expect(SourceAccess.isSourceAvailable(item: symlinkItem, documentURL: nil))

        let appsLink = CanvasItem(kind: .applicationsSymlink, label: "Applications", position: .zero)
        #expect(SourceAccess.isSourceAvailable(item: appsLink, documentURL: nil))
    }

    @Test
    func `Copy item with no source path is unavailable`() {
        let item = CanvasItem(kind: .file, label: "F", position: .zero)
        #expect(!SourceAccess.isSourceAvailable(item: item, documentURL: nil))
    }

    // MARK: - Document Missing-Source State

    @Test
    @MainActor
    func `refreshSourceStates flags deleted sources and clears restored ones`() throws {
        let file = try makeTempFile()
        defer { cleanup(file) }

        let doc = RilmazafoneDocument()
        let item = CanvasItem(kind: .file, label: "F", sourcePath: file.path, position: .zero)
        doc.addItem(item, undoManager: nil)
        #expect(!doc.missingSourceIDs.contains(item.id))

        try FileManager.default.removeItem(at: file)
        doc.refreshSourceStates()
        #expect(doc.missingSourceIDs.contains(item.id))

        try Data("restored".utf8).write(to: file)
        doc.refreshSourceStates()
        #expect(!doc.missingSourceIDs.contains(item.id))
    }

    @Test
    @MainActor
    func `GitHub-created document (path only, no bookmark) with a dead path shows missing, not crash`() {
        let doc = RilmazafoneDocument()
        let item = CanvasItem(
            kind: .app,
            label: "Gone.app",
            sourcePath: "/nonexistent/Gone.app",
            position: .zero,
        )
        doc.addItem(item, undoManager: nil)
        doc.documentFileURLDidChange(nil)

        #expect(doc.missingSourceIDs.contains(item.id))
    }

    // MARK: - Relink

    @Test
    @MainActor
    func `relinkItem updates the source path, clears missing state, and resolves the icon`() async throws {
        let original = try makeTempFile(named: "original.txt")
        defer { cleanup(original) }
        let replacement = try makeTempFile(named: "replacement.txt")
        defer { cleanup(replacement) }

        let doc = RilmazafoneDocument()
        let item = CanvasItem(kind: .file, label: "F", sourcePath: original.path, position: .zero)
        doc.addItem(item, undoManager: nil)

        try FileManager.default.removeItem(at: original)
        doc.refreshSourceStates()
        #expect(doc.missingSourceIDs.contains(item.id))
        #expect(CanvasItem.resolveIcon(for: doc.configuration.items[0]) == nil)

        await doc.relinkItem(item.id, to: replacement, undoManager: nil)

        let relinked = try #require(doc.configuration.items.first { $0.id == item.id })
        #expect(relinked.sourcePath == replacement.path)
        #expect(!doc.missingSourceIDs.contains(item.id))
        #expect(CanvasItem.resolveIcon(for: relinked) != nil)
        #if !APPSTORE
            #expect(relinked.sourceBookmark == nil)
        #endif
    }

    @Test
    @MainActor
    func `relinkItem is undoable: undo restores the previous source path and bookmark`() async throws {
        let replacement = try makeTempFile(named: "replacement.txt")
        defer { cleanup(replacement) }

        let doc = RilmazafoneDocument()
        let oldBookmark = Data([9, 9, 9])
        let item = CanvasItem(
            kind: .file,
            label: "F",
            sourcePath: "/nonexistent/old.txt",
            sourceBookmark: oldBookmark,
            position: .zero,
        )
        doc.addItem(item, undoManager: nil)

        let undoManager = UndoManager()
        await doc.relinkItem(item.id, to: replacement, undoManager: undoManager)
        #expect(doc.configuration.items[0].sourcePath == replacement.path)

        undoManager.undo()
        #expect(doc.configuration.items[0].sourcePath == "/nonexistent/old.txt")
        #expect(doc.configuration.items[0].sourceBookmark == oldBookmark)
        #expect(doc.missingSourceIDs.contains(item.id))
    }

    // MARK: - Build Validation

    @Test
    func `validateSources throws missingSources listing offending labels`() throws {
        var config = DMGConfiguration()
        config.items = [
            CanvasItem(kind: .app, label: "Gone.app", sourcePath: "/nonexistent/Gone.app", position: .zero),
            CanvasItem(kind: .file, label: "Absent.txt", position: .zero),
            CanvasItem(kind: .applicationsSymlink, label: "Applications", position: .zero),
        ]

        #expect {
            try DMGBuildPipeline.validateSources(configuration: config, documentURL: nil)
        } throws: { error in
            guard case let .missingSources(labels) = error as? ValidationError else { return false }
            return labels == ["Gone.app", "Absent.txt"]
        }
    }

    @Test
    func `validateSources passes when all copy sources exist`() throws {
        let file = try makeTempFile()
        defer { cleanup(file) }

        var symlinkItem = CanvasItem(
            kind: .folder, label: "Link", sourcePath: "/nonexistent/target", position: .zero,
        )
        symlinkItem.linkType = .symlink

        var config = DMGConfiguration()
        config.items = [
            CanvasItem(kind: .file, label: "F", sourcePath: file.path, position: .zero),
            symlinkItem,
            CanvasItem(kind: .applicationsSymlink, label: "Applications", position: .zero),
        ]

        try DMGBuildPipeline.validateSources(configuration: config, documentURL: nil)
    }
}
