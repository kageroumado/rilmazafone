import CoreGraphics
import Foundation
import Testing
@testable import Rilmazafone

@Suite("RilmazafoneDocument")
struct DocumentTests {
    // MARK: - Clamping

    @Test("setIconSize clamps below 16 to 16")
    @MainActor
    func iconSizeClampLow() {
        let doc = RilmazafoneDocument()
        doc.setIconSize(8, undoManager: nil)
        #expect(doc.configuration.iconSize == 16)
    }

    @Test("setIconSize clamps above 512 to 512")
    @MainActor
    func iconSizeClampHigh() {
        let doc = RilmazafoneDocument()
        doc.setIconSize(1_024, undoManager: nil)
        #expect(doc.configuration.iconSize == 512)
    }

    @Test("setIconSize passes through valid values")
    @MainActor
    func iconSizeValid() {
        let doc = RilmazafoneDocument()
        doc.setIconSize(128, undoManager: nil)
        #expect(doc.configuration.iconSize == 128)
    }

    @Test("setTextSize clamps below 10 to 10")
    @MainActor
    func textSizeClampLow() {
        let doc = RilmazafoneDocument()
        doc.setTextSize(5, undoManager: nil)
        #expect(doc.configuration.textSize == 10)
    }

    @Test("setTextSize clamps above 16 to 16")
    @MainActor
    func textSizeClampHigh() {
        let doc = RilmazafoneDocument()
        doc.setTextSize(24, undoManager: nil)
        #expect(doc.configuration.textSize == 16)
    }

    @Test("setGridSpacing clamps below 1 to 1")
    @MainActor
    func gridSpacingClampLow() {
        let doc = RilmazafoneDocument()
        doc.setGridSpacing(0, undoManager: nil)
        #expect(doc.configuration.gridSpacing == 1)
    }

    @Test("setGridSpacing clamps above 100 to 100")
    @MainActor
    func gridSpacingClampHigh() {
        let doc = RilmazafoneDocument()
        doc.setGridSpacing(200, undoManager: nil)
        #expect(doc.configuration.gridSpacing == 100)
    }

    // MARK: - Undo

    @Test("setIconSize undo restores previous value")
    @MainActor
    func iconSizeUndo() {
        let doc = RilmazafoneDocument()
        let undoManager = UndoManager()
        doc.configuration.iconSize = 100

        doc.setIconSize(200, undoManager: undoManager)
        #expect(doc.configuration.iconSize == 200)

        undoManager.undo()
        #expect(doc.configuration.iconSize == 100)
    }

    @Test("setIconSize redo re-applies value")
    @MainActor
    func iconSizeRedo() {
        let doc = RilmazafoneDocument()
        let undoManager = UndoManager()
        doc.configuration.iconSize = 100

        doc.setIconSize(200, undoManager: undoManager)
        undoManager.undo()
        undoManager.redo()

        #expect(doc.configuration.iconSize == 200)
    }

    @Test("setVolumeName undo/redo cycle")
    @MainActor
    func volumeNameUndoRedo() {
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

    @Test("hasApp returns false when no items")
    @MainActor
    func hasAppEmpty() {
        let doc = RilmazafoneDocument()
        #expect(doc.hasApp == false)
    }

    @Test("hasApp returns true when app item exists")
    @MainActor
    func hasAppTrue() {
        let doc = RilmazafoneDocument()
        doc.configuration.items = [
            CanvasItem(kind: .app, label: "Test.app", position: .zero),
        ]
        #expect(doc.hasApp == true)
    }

    @Test("hasApp returns false with only non-app items")
    @MainActor
    func hasAppFalseNonApp() {
        let doc = RilmazafoneDocument()
        doc.configuration.items = [
            CanvasItem(kind: .applicationsSymlink, label: "Applications", position: .zero),
            CanvasItem(kind: .file, label: "readme.txt", position: .zero),
        ]
        #expect(doc.hasApp == false)
    }

    // MARK: - Item Management

    @Test("addItem appends to items list")
    @MainActor
    func addItem() {
        let doc = RilmazafoneDocument()
        let item = CanvasItem(kind: .file, label: "test.txt", position: CGPoint(x: 100, y: 200))
        doc.addItem(item, undoManager: nil)

        #expect(doc.configuration.items.count == 1)
        #expect(doc.configuration.items[0].label == "test.txt")
    }

    @Test("removeItem removes from items list")
    @MainActor
    func removeItem() {
        let doc = RilmazafoneDocument()
        let item = CanvasItem(kind: .file, label: "test.txt", position: .zero)
        doc.configuration.items = [item]

        doc.removeItem(item.id, undoManager: nil)
        #expect(doc.configuration.items.isEmpty)
    }

    @Test("removeItem undo restores item")
    @MainActor
    func removeItemUndo() {
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

    @Test("moveItem updates position")
    @MainActor
    func moveItem() {
        let doc = RilmazafoneDocument()
        let item = CanvasItem(kind: .app, label: "App.app", position: CGPoint(x: 100, y: 100))
        doc.configuration.items = [item]

        doc.moveItem(item.id, to: CGPoint(x: 200, y: 300), undoManager: nil)

        #expect(doc.configuration.items[0].position == CGPoint(x: 200, y: 300))
    }

    @Test("setItemLabel updates label")
    @MainActor
    func setItemLabel() {
        let doc = RilmazafoneDocument()
        let item = CanvasItem(kind: .file, label: "old.txt", position: .zero)
        doc.configuration.items = [item]

        doc.setItemLabel(item.id, to: "new.txt", undoManager: nil)
        #expect(doc.configuration.items[0].label == "new.txt")
    }

    // MARK: - Layer Management

    @Test("addTextLayer creates a text layer at center")
    @MainActor
    func addTextLayer() {
        let doc = RilmazafoneDocument()
        doc.addTextLayer(undoManager: nil)

        #expect(doc.configuration.textLayers.count == 1)
        // Auto-centers: window default is 660x400 → center = (330, 200)
        #expect(doc.configuration.textLayers[0].position == CGPoint(x: 330, y: 200))
        #expect(doc.configuration.textLayers[0].text == "Text")
    }

    @Test("removeTextLayer removes the layer")
    @MainActor
    func removeTextLayer() {
        let doc = RilmazafoneDocument()
        doc.addTextLayer(undoManager: nil)
        let id = doc.configuration.textLayers[0].id

        doc.removeTextLayer(id, undoManager: nil)
        #expect(doc.configuration.textLayers.isEmpty)
    }

    @Test("removeTextLayer undo restores the layer")
    @MainActor
    func removeTextLayerUndo() {
        let doc = RilmazafoneDocument()
        let undoManager = UndoManager()
        doc.addTextLayer(undoManager: nil)
        let id = doc.configuration.textLayers[0].id

        doc.removeTextLayer(id, undoManager: undoManager)
        undoManager.undo()

        #expect(doc.configuration.textLayers.count == 1)
        #expect(doc.configuration.textLayers[0].id == id)
    }

    @Test("updateTextLayerStyle updates all style properties atomically")
    @MainActor
    func updateTextLayerStyle() {
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

    @Test("addSFSymbolLayer creates a symbol layer")
    @MainActor
    func addSFSymbolLayer() {
        let doc = RilmazafoneDocument()
        doc.addSFSymbolLayer(undoManager: nil)

        #expect(doc.configuration.sfSymbolLayers.count == 1)
        // Auto-centers: window default is 660x400 → center = (330, 200)
        #expect(doc.configuration.sfSymbolLayers[0].position == CGPoint(x: 330, y: 200))
    }

    // MARK: - Snapshot

    @Test("Snapshot abbreviates paths without mutating document")
    @MainActor
    func snapshotAbbreviatesPaths() throws {
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

    @Test("setBackgroundType changes background type")
    @MainActor
    func backgroundTypeChange() {
        let doc = RilmazafoneDocument()
        doc.setBackgroundType(.color, undoManager: nil)
        #expect(doc.configuration.background.type == .color)
    }

    @Test("setBackgroundColor updates RGB values")
    @MainActor
    func backgroundColorChange() {
        let doc = RilmazafoneDocument()
        let color = RGBColor(red: 0.1, green: 0.2, blue: 0.3)
        doc.setBackgroundColor(color, undoManager: nil)

        #expect(doc.configuration.background.color.red == 0.1)
        #expect(doc.configuration.background.color.green == 0.2)
        #expect(doc.configuration.background.color.blue == 0.3)
    }
}
