import CoreGraphics
import Foundation
import Testing
@testable import Rilmazafone

@Suite("Placeholder App Slot")
struct PlaceholderTests {
    // MARK: - Model

    @Test("appPlaceholder factory produces an unfilled app slot")
    func factoryDefaults() {
        let placeholder = CanvasItem.appPlaceholder(position: CGPoint(x: 40, y: 50))
        #expect(placeholder.kind == .app)
        #expect(placeholder.isPlaceholder == true)
        #expect(placeholder.label == CanvasItem.placeholderLabel)
        #expect(placeholder.sourcePath == nil)
        #expect(placeholder.position == CGPoint(x: 40, y: 50))
        #expect(placeholder.placeholderGlyphName == "app.dashed")
    }

    @Test("folderPlaceholder factory produces an unfilled folder slot")
    func folderFactoryDefaults() {
        let placeholder = CanvasItem.folderPlaceholder(position: CGPoint(x: 40, y: 50))
        #expect(placeholder.kind == .folder)
        #expect(placeholder.isPlaceholder == true)
        #expect(placeholder.label == CanvasItem.folderPlaceholderLabel)
        #expect(placeholder.sourcePath == nil)
        #expect(placeholder.requiresSource == false)
        #expect(placeholder.placeholderGlyphName == "folder")
    }

    @Test("filePlaceholder factory produces an unfilled file slot")
    func fileFactoryDefaults() {
        let placeholder = CanvasItem.filePlaceholder(position: CGPoint(x: 40, y: 50))
        #expect(placeholder.kind == .file)
        #expect(placeholder.isPlaceholder == true)
        #expect(placeholder.label == CanvasItem.filePlaceholderLabel)
        #expect(placeholder.sourcePath == nil)
        #expect(placeholder.requiresSource == false)
        #expect(placeholder.placeholderGlyphName == "doc")
    }

    @Test("A placeholder does not require a source")
    func placeholderDoesNotRequireSource() {
        let placeholder = CanvasItem.appPlaceholder(position: .zero)
        #expect(placeholder.requiresSource == false)
        #expect(SourceAccess.isSourceAvailable(item: placeholder, documentURL: nil) == true)
    }

    // MARK: - Codable

    @Test("CanvasItem round-trips isPlaceholder through JSON")
    func placeholderCodableRoundTrip() throws {
        let placeholder = CanvasItem.appPlaceholder(position: CGPoint(x: 12, y: 34))
        let encoded = try JSONEncoder().encode(placeholder)
        let decoded = try JSONDecoder().decode(CanvasItem.self, from: encoded)

        #expect(decoded.isPlaceholder == true)
        #expect(decoded == placeholder)
    }

    @Test("Legacy JSON without isPlaceholder decodes to false")
    func placeholderCodableLegacyDefault() throws {
        let item = CanvasItem(kind: .app, label: "MyApp.app", position: CGPoint(x: 1, y: 2))
        let encoded = try JSONEncoder().encode(item)
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "isPlaceholder")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(CanvasItem.self, from: legacy)
        #expect(decoded.isPlaceholder == false)
    }

    // MARK: - Missing-Source Exclusion

    @Test("A placeholder is excluded from the missing-source set")
    @MainActor
    func placeholderExcludedFromMissingSources() {
        let doc = RilmazafoneDocument()
        let placeholder = CanvasItem.appPlaceholder(position: .zero)
        doc.configuration.items = [placeholder]

        doc.refreshSourceStates()
        #expect(doc.missingSourceIDs.contains(placeholder.id) == false)
        #expect(doc.missingSourceIDs.isEmpty)
    }

    // MARK: - Fill In Place

    @Test("Filling a placeholder preserves position and replaces label and source")
    @MainActor
    func fillPreservesPositionReplacesLabelAndSource() async {
        let doc = RilmazafoneDocument()
        let placeholder = CanvasItem.appPlaceholder(position: CGPoint(x: 150, y: 210))
        let id = placeholder.id
        doc.configuration.items = [placeholder]

        let appURL = URL(fileURLWithPath: "/tmp/rilmazafone-test-FillMe.app")
        await doc.fillPlaceholder(id, from: appURL, undoManager: nil)

        let filled = doc.configuration.items[0]
        #expect(filled.id == id)
        #expect(filled.isPlaceholder == false)
        #expect(filled.position == CGPoint(x: 150, y: 210))
        #expect(filled.label == "rilmazafone-test-FillMe.app")
        #expect(filled.sourcePath == appURL.path)
    }

    @Test("Filling fills the first placeholder without adding an item")
    @MainActor
    func fillDoesNotAddItem() async {
        let doc = RilmazafoneDocument()
        let placeholder = CanvasItem.appPlaceholder(position: CGPoint(x: 100, y: 100))
        doc.configuration.items = [
            placeholder,
            CanvasItem(kind: .applicationsSymlink, label: "Applications", position: CGPoint(x: 300, y: 100)),
        ]

        await doc.handleDrop(
            urls: [URL(fileURLWithPath: "/tmp/rilmazafone-test-Dropped.app")],
            defaultPosition: .zero,
            undoManager: nil
        )

        #expect(doc.configuration.items.count == 2)
        #expect(doc.configuration.items.contains { $0.isPlaceholder } == false)
        let app = doc.configuration.items.first { $0.kind == .app }
        #expect(app?.label == "rilmazafone-test-Dropped.app")
        #expect(app?.position == CGPoint(x: 100, y: 100))
    }

    @Test("Dropping a folder fills the first folder slot, not the app slot")
    @MainActor
    func folderDropFillsFolderSlot() async {
        let doc = RilmazafoneDocument()
        let appSlot = CanvasItem.appPlaceholder(position: CGPoint(x: 100, y: 100))
        let folderSlot = CanvasItem.folderPlaceholder(position: CGPoint(x: 300, y: 100))
        doc.configuration.items = [appSlot, folderSlot]

        await doc.handleDrop(
            urls: [URL(fileURLWithPath: "/tmp/rilmazafone-test-Docs", isDirectory: true)],
            defaultPosition: .zero,
            undoManager: nil
        )

        #expect(doc.configuration.items.count == 2)
        let app = doc.configuration.items[0]
        let folder = doc.configuration.items[1]
        #expect(app.isPlaceholder == true, "app slot must stay unfilled")
        #expect(folder.isPlaceholder == false)
        #expect(folder.kind == .folder)
        #expect(folder.label == "rilmazafone-test-Docs")
        #expect(folder.position == CGPoint(x: 300, y: 100))
    }

    @Test("Dropping a file fills the first file slot")
    @MainActor
    func fileDropFillsFileSlot() async {
        let doc = RilmazafoneDocument()
        let fileSlot = CanvasItem.filePlaceholder(position: CGPoint(x: 220, y: 260))
        doc.configuration.items = [fileSlot]

        await doc.handleDrop(
            urls: [URL(fileURLWithPath: "/tmp/rilmazafone-test-ReadMe.txt")],
            defaultPosition: .zero,
            undoManager: nil
        )

        #expect(doc.configuration.items.count == 1)
        let file = doc.configuration.items[0]
        #expect(file.isPlaceholder == false)
        #expect(file.kind == .file)
        #expect(file.label == "rilmazafone-test-ReadMe.txt")
        #expect(file.position == CGPoint(x: 220, y: 260))
    }

    @Test("Dropping a file with no file slot adds a new item")
    @MainActor
    func fileDropWithoutSlotAddsItem() async {
        let doc = RilmazafoneDocument()
        let appSlot = CanvasItem.appPlaceholder(position: CGPoint(x: 100, y: 100))
        doc.configuration.items = [appSlot]

        await doc.handleDrop(
            urls: [URL(fileURLWithPath: "/tmp/rilmazafone-test-Extra.txt")],
            defaultPosition: CGPoint(x: 400, y: 300),
            undoManager: nil
        )

        #expect(doc.configuration.items.count == 2)
        #expect(doc.configuration.items[0].isPlaceholder == true, "app slot must stay unfilled")
        let added = doc.configuration.items[1]
        #expect(added.kind == .file)
        #expect(added.isPlaceholder == false)
        #expect(added.position == CGPoint(x: 400, y: 300))
    }

    @Test("Undo restores a filled folder slot")
    @MainActor
    func undoRestoresFolderSlot() async {
        let doc = RilmazafoneDocument()
        let undoManager = UndoManager()
        let folderSlot = CanvasItem.folderPlaceholder(position: CGPoint(x: 300, y: 100))
        let id = folderSlot.id
        doc.configuration.items = [folderSlot]

        await doc.fillPlaceholder(
            id,
            from: URL(fileURLWithPath: "/tmp/rilmazafone-test-Docs", isDirectory: true),
            undoManager: undoManager
        )
        #expect(doc.configuration.items[0].isPlaceholder == false)

        undoManager.undo()
        let restored = doc.configuration.items[0]
        #expect(restored.isPlaceholder == true)
        #expect(restored.kind == .folder)
        #expect(restored.label == CanvasItem.folderPlaceholderLabel)
        #expect(restored.sourcePath == nil)
        #expect(restored.position == CGPoint(x: 300, y: 100))
    }

    @Test("Undo restores the placeholder after a fill")
    @MainActor
    func undoRestoresPlaceholder() async {
        let doc = RilmazafoneDocument()
        let undoManager = UndoManager()
        let placeholder = CanvasItem.appPlaceholder(position: CGPoint(x: 150, y: 210))
        let id = placeholder.id
        doc.configuration.items = [placeholder]

        await doc.fillPlaceholder(id, from: URL(fileURLWithPath: "/tmp/rilmazafone-test-FillMe.app"), undoManager: undoManager)
        #expect(doc.configuration.items[0].isPlaceholder == false)

        undoManager.undo()

        let restored = doc.configuration.items[0]
        #expect(restored.id == id)
        #expect(restored.isPlaceholder == true)
        #expect(restored.label == CanvasItem.placeholderLabel)
        #expect(restored.sourcePath == nil)
        #expect(restored.position == CGPoint(x: 150, y: 210))
    }

    @Test("Redo re-fills the placeholder after an undo")
    @MainActor
    func redoRefillsPlaceholder() async {
        let doc = RilmazafoneDocument()
        let undoManager = UndoManager()
        let placeholder = CanvasItem.appPlaceholder(position: .zero)
        let id = placeholder.id
        doc.configuration.items = [placeholder]

        await doc.fillPlaceholder(id, from: URL(fileURLWithPath: "/tmp/rilmazafone-test-FillMe.app"), undoManager: undoManager)
        undoManager.undo()
        #expect(doc.configuration.items[0].isPlaceholder == true)

        undoManager.redo()
        #expect(doc.configuration.items[0].isPlaceholder == false)
        #expect(doc.configuration.items[0].label == "rilmazafone-test-FillMe.app")
    }

    // MARK: - Build Validation

    @Test("Building with an unfilled placeholder throws unfilledPlaceholder naming the slot")
    func validationBlocksUnfilledPlaceholder() {
        var config = DMGConfiguration()
        config.items = [CanvasItem.appPlaceholder(position: .zero)]

        #expect {
            try DMGBuildPipeline.validateSources(configuration: config, documentURL: nil)
        } throws: { error in
            guard case let ValidationError.unfilledPlaceholder(labels) = error else { return false }
            return labels == [CanvasItem.placeholderLabel]
        }
    }

    @Test("Validation names every unfilled slot across kinds")
    func validationNamesAllUnfilledSlots() {
        var config = DMGConfiguration()
        config.items = [
            CanvasItem.appPlaceholder(position: .zero),
            CanvasItem.folderPlaceholder(position: .zero),
            CanvasItem.filePlaceholder(position: .zero),
        ]

        #expect {
            try DMGBuildPipeline.validateSources(configuration: config, documentURL: nil)
        } throws: { error in
            guard case let ValidationError.unfilledPlaceholder(labels) = error else { return false }
            return Set(labels) == [
                CanvasItem.placeholderLabel,
                CanvasItem.folderPlaceholderLabel,
                CanvasItem.filePlaceholderLabel,
            ]
        }
    }

    @Test("Placeholder validation takes precedence over missing sources")
    func placeholderValidationPrecedence() {
        var config = DMGConfiguration()
        config.items = [
            CanvasItem.appPlaceholder(position: .zero),
            CanvasItem(kind: .file, label: "Gone.txt", sourcePath: "/tmp/does-not-exist-\(UUID()).txt", position: .zero),
        ]

        #expect {
            try DMGBuildPipeline.validateSources(configuration: config, documentURL: nil)
        } throws: { error in
            guard case ValidationError.unfilledPlaceholder = error else { return false }
            return true
        }
    }

    func filledConfigurationValidates() throws {
        var config = DMGConfiguration()
        // A symlink-only item needs no reachable source, so validation passes.
        config.items = [
            CanvasItem(kind: .applicationsSymlink, label: "Applications", position: .zero),
        ]
        try DMGBuildPipeline.validateSources(configuration: config, documentURL: nil)
    }
}
