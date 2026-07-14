import CoreGraphics
import Foundation
import Testing
@testable import Rilmazafone

@Suite("RilmazafoneDocument")
struct DocumentTests {
    // MARK: - Clamping

    @Test
    @MainActor
    func `setIconSize clamps below 16 to 16`() {
        let doc = RilmazafoneDocument()
        doc.setIconSize(8, undoManager: nil)
        #expect(doc.configuration.iconSize == 16)
    }

    @Test
    @MainActor
    func `setIconSize clamps above 512 to 512`() {
        let doc = RilmazafoneDocument()
        doc.setIconSize(1_024, undoManager: nil)
        #expect(doc.configuration.iconSize == 512)
    }

    @Test
    @MainActor
    func `setIconSize passes through valid values`() {
        let doc = RilmazafoneDocument()
        doc.setIconSize(128, undoManager: nil)
        #expect(doc.configuration.iconSize == 128)
    }

    @Test
    @MainActor
    func `setTextSize clamps below 10 to 10`() {
        let doc = RilmazafoneDocument()
        doc.setTextSize(5, undoManager: nil)
        #expect(doc.configuration.textSize == 10)
    }

    @Test
    @MainActor
    func `setTextSize clamps above 16 to 16`() {
        let doc = RilmazafoneDocument()
        doc.setTextSize(24, undoManager: nil)
        #expect(doc.configuration.textSize == 16)
    }

    @Test
    @MainActor
    func `setGridSpacing clamps below 1 to 1`() {
        let doc = RilmazafoneDocument()
        doc.setGridSpacing(0, undoManager: nil)
        #expect(doc.configuration.gridSpacing == 1)
    }

    @Test
    @MainActor
    func `setGridSpacing clamps above 100 to 100`() {
        let doc = RilmazafoneDocument()
        doc.setGridSpacing(200, undoManager: nil)
        #expect(doc.configuration.gridSpacing == 100)
    }

    // MARK: - Undo

    @Test
    @MainActor
    func `setIconSize undo restores previous value`() {
        let doc = RilmazafoneDocument()
        let undoManager = UndoManager()
        doc.configuration.iconSize = 100

        doc.setIconSize(200, undoManager: undoManager)
        #expect(doc.configuration.iconSize == 200)

        undoManager.undo()
        #expect(doc.configuration.iconSize == 100)
    }

    @Test
    @MainActor
    func `setIconSize redo re-applies value`() {
        let doc = RilmazafoneDocument()
        let undoManager = UndoManager()
        doc.configuration.iconSize = 100

        doc.setIconSize(200, undoManager: undoManager)
        undoManager.undo()
        undoManager.redo()

        #expect(doc.configuration.iconSize == 200)
    }

    @Test
    @MainActor
    func `setVolumeName undo/redo cycle`() {
        let doc = RilmazafoneDocument()
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        undoManager.beginUndoGrouping()
        doc.setVolumeName("First", undoManager: undoManager)
        undoManager.endUndoGrouping()

        undoManager.beginUndoGrouping()
        doc.setVolumeName("Second", undoManager: undoManager)
        undoManager.endUndoGrouping()

        #expect(doc.configuration.volumeName == "Second")
        undoManager.undo()
        #expect(doc.configuration.volumeName == "First")
        undoManager.undo()
        #expect(doc.configuration.volumeName == "Untitled")
    }

    // MARK: - Queries

    @Test
    @MainActor
    func `hasApp returns false when no items`() {
        let doc = RilmazafoneDocument()
        #expect(doc.hasApp == false)
    }

    @Test
    @MainActor
    func `hasApp returns true when app item exists`() {
        let doc = RilmazafoneDocument()
        doc.configuration.items = [
            CanvasItem(kind: .app, label: "Test.app", position: .zero),
        ]
        #expect(doc.hasApp == true)
    }

    @Test
    @MainActor
    func `hasApp returns false with only non-app items`() {
        let doc = RilmazafoneDocument()
        doc.configuration.items = [
            CanvasItem(kind: .applicationsSymlink, label: "Applications", position: .zero),
            CanvasItem(kind: .file, label: "readme.txt", position: .zero),
        ]
        #expect(doc.hasApp == false)
    }

    // MARK: - Item Management

    @Test
    @MainActor
    func `addItem appends to items list`() {
        let doc = RilmazafoneDocument()
        let item = CanvasItem(kind: .file, label: "test.txt", position: CGPoint(x: 100, y: 200))
        doc.addItem(item, undoManager: nil)

        #expect(doc.configuration.items.count == 1)
        #expect(doc.configuration.items[0].label == "test.txt")
    }

    @Test
    @MainActor
    func `removeItem removes from items list`() {
        let doc = RilmazafoneDocument()
        let item = CanvasItem(kind: .file, label: "test.txt", position: .zero)
        doc.configuration.items = [item]

        doc.removeItem(item.id, undoManager: nil)
        #expect(doc.configuration.items.isEmpty)
    }

    @Test
    @MainActor
    func `removeItem undo restores item`() {
        let doc = RilmazafoneDocument()
        let undoManager = UndoManager()
        let item = CanvasItem(kind: .file, label: "test.txt", position: CGPoint(x: 50, y: 100))
        doc.configuration.items = [item]

        doc.removeItem(item.id, undoManager: undoManager)
        #expect(doc.configuration.items.isEmpty)

        undoManager.undo()
        #expect(doc.configuration.items.count == 1)
        #expect(doc.configuration.items[0].label == "test.txt")
        #expect(doc.configuration.items[0].position == CGPoint(x: 50, y: 100))
    }

    @Test
    @MainActor
    func `moveItem updates position`() {
        let doc = RilmazafoneDocument()
        let item = CanvasItem(kind: .app, label: "App.app", position: CGPoint(x: 100, y: 100))
        doc.configuration.items = [item]

        doc.moveItem(item.id, to: CGPoint(x: 200, y: 300), undoManager: nil)

        #expect(doc.configuration.items[0].position == CGPoint(x: 200, y: 300))
    }

    @Test
    @MainActor
    func `setItemLabel updates label`() {
        let doc = RilmazafoneDocument()
        let item = CanvasItem(kind: .file, label: "old.txt", position: .zero)
        doc.configuration.items = [item]

        doc.setItemLabel(item.id, to: "new.txt", undoManager: nil)
        #expect(doc.configuration.items[0].label == "new.txt")
    }

    // MARK: - Layer Management

    @Test
    @MainActor
    func `addTextLayer creates a text layer at center`() {
        let doc = RilmazafoneDocument()
        doc.addTextLayer(undoManager: nil)

        #expect(doc.configuration.textLayers.count == 1)
        // Auto-centers: window default is 660x400 → center = (330, 200)
        #expect(doc.configuration.textLayers[0].position == CGPoint(x: 330, y: 200))
        #expect(doc.configuration.textLayers[0].text == "Text")
    }

    @Test
    @MainActor
    func `removeTextLayer removes the layer`() {
        let doc = RilmazafoneDocument()
        doc.addTextLayer(undoManager: nil)
        let id = doc.configuration.textLayers[0].id

        doc.removeTextLayer(id, undoManager: nil)
        #expect(doc.configuration.textLayers.isEmpty)
    }

    @Test
    @MainActor
    func `removeTextLayer undo restores the layer`() {
        let doc = RilmazafoneDocument()
        let undoManager = UndoManager()
        doc.addTextLayer(undoManager: nil)
        let id = doc.configuration.textLayers[0].id

        doc.removeTextLayer(id, undoManager: undoManager)
        undoManager.undo()

        #expect(doc.configuration.textLayers.count == 1)
        #expect(doc.configuration.textLayers[0].id == id)
    }

    @Test
    @MainActor
    func `updateTextLayerStyle updates all style properties atomically`() {
        let doc = RilmazafoneDocument()
        doc.addTextLayer(undoManager: nil)
        let id = doc.configuration.textLayers[0].id

        doc.updateTextLayerStyle(id, with: {
            $0.fontFamily = "Menlo"
            $0.fontSize = 36
            $0.isBold = true
            $0.isItalic = true
            $0.color = RGBColor(red: 1, green: 0, blue: 0)
        }, undoManager: nil)

        let layer = doc.configuration.textLayers[0]
        #expect(layer.fontFamily == "Menlo")
        #expect(layer.fontSize == 36)
        #expect(layer.isBold == true)
        #expect(layer.isItalic == true)
        #expect(layer.color.red == 1)
    }

    @Test
    @MainActor
    func `addSFSymbolLayer creates a symbol layer`() {
        let doc = RilmazafoneDocument()
        doc.addSFSymbolLayer(undoManager: nil)

        #expect(doc.configuration.sfSymbolLayers.count == 1)
        // Auto-centers: window default is 660x400 → center = (330, 200)
        #expect(doc.configuration.sfSymbolLayers[0].position == CGPoint(x: 330, y: 200))
    }

    // MARK: - Snapshot

    @Test
    @MainActor
    func `Snapshot abbreviates paths without mutating document`() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let doc = RilmazafoneDocument()
        doc.configuration.items = [
            CanvasItem(kind: .app, label: "App.app", sourcePath: "\(home)/Apps/App.app", position: .zero),
        ]

        let snapshot = try doc.snapshot(contentType: .rilmazafoneDocument)

        // Snapshot has abbreviated paths
        #expect(snapshot.configuration.items[0].sourcePath == "~/Apps/App.app")

        // Document is NOT mutated
        #expect(doc.configuration.items[0].sourcePath == "\(home)/Apps/App.app")
    }

    // MARK: - Background Type Transitions

    @Test
    @MainActor
    func `setBackgroundType changes background type`() {
        let doc = RilmazafoneDocument()
        doc.setBackgroundType(.color, undoManager: nil)
        #expect(doc.configuration.background.type == .color)
    }

    @Test
    @MainActor
    func `setBackgroundColor updates RGB values`() {
        let doc = RilmazafoneDocument()
        let color = RGBColor(red: 0.1, green: 0.2, blue: 0.3)
        doc.setBackgroundColor(color, undoManager: nil)

        #expect(doc.configuration.background.color.red == 0.1)
        #expect(doc.configuration.background.color.green == 0.2)
        #expect(doc.configuration.background.color.blue == 0.3)
    }
}
