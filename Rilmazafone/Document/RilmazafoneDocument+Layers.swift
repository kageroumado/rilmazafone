import AppKit
@preconcurrency import Combine
import Foundation

extension RilmazafoneDocument {
    // MARK: - Background Layer Management

    func addBackgroundLayer(from url: URL, undoManager: UndoManager?) throws {
        let data = try Data(contentsOf: url)
        let layerID = UUID()
        let filename = "bg-\(layerID.uuidString).\(url.pathExtension)"

        ensureAssetsWrapper()
        replaceAsset(named: filename, with: data)

        let layer = BackgroundLayer(
            id: layerID,
            imageName: filename,
            label: url.lastPathComponent,
            position: CGPoint(
                x: window.width / 2,
                y: window.height / 2
            )
        )
        background.layers.append(layer)

        if let image = NSImage(data: data) {
            backgroundImages[layerID] = image
        }

        if background.type != .image {
            background.type = .image
        }

        objectWillChange.send()
        withUndo(undoManager, "Add Background Image") { doc, um in
            doc.removeBackgroundLayer(layerID, undoManager: um)
        }
    }

    func removeBackgroundLayer(_ id: UUID, undoManager: UndoManager?) {
        guard let index = background.layers.firstIndex(where: { $0.id == id }) else {
            return
        }
        let removed = background.layers.remove(at: index)
        let removedImage = backgroundImages.removeValue(forKey: id)

        if let wrapper = assetsWrapper?.fileWrappers?[removed.imageName] {
            assetsWrapper?.removeFileWrapper(wrapper)
        }

        if background.layers.isEmpty, background.type == .image {
            background.type = .color
        }

        objectWillChange.send()
        withUndo(undoManager, "Remove Background Image") { doc, um in
            doc.background.layers.insert(removed, at: min(index, doc.background.layers.count))
            if let img = removedImage {
                doc.backgroundImages[id] = img
            }
            if doc.background.type != .image {
                doc.background.type = .image
            }
            doc.objectWillChange.send()
            doc.withUndo(um, "Add Background Image") { doc, um in
                doc.removeBackgroundLayer(id, undoManager: um)
            }
        }
    }

    func moveBackgroundLayer(_ id: UUID, to newPosition: CGPoint, undoManager: UndoManager?) {
        guard let index = background.layers.firstIndex(where: { $0.id == id }) else {
            return
        }
        let oldPosition = background.layers[index].position
        let rounded = CGPoint(x: round(newPosition.x), y: round(newPosition.y))
        background.layers[index].position = rounded
        objectWillChange.send()
        withUndo(undoManager, "Move Background Image") { doc, um in
            doc.moveBackgroundLayer(id, to: oldPosition, undoManager: um)
        }
    }

    func setBackgroundLayerScale(_ id: UUID, to newScale: CGFloat, undoManager: UndoManager?) {
        guard let index = background.layers.firstIndex(where: { $0.id == id }) else {
            return
        }
        let oldScale = background.layers[index].scale
        background.layers[index].scale = newScale
        objectWillChange.send()
        withUndo(undoManager, "Scale Background Image") { doc, um in
            doc.setBackgroundLayerScale(id, to: oldScale, undoManager: um)
        }
    }

    func setBackgroundLayerBlur(_ id: UUID, to newBlur: CGFloat, undoManager: UndoManager?) {
        guard let index = background.layers.firstIndex(where: { $0.id == id }) else {
            return
        }
        let oldBlur = background.layers[index].blurRadius
        background.layers[index].blurRadius = newBlur
        objectWillChange.send()
        withUndo(undoManager, "Change Layer Blur") { doc, um in
            doc.setBackgroundLayerBlur(id, to: oldBlur, undoManager: um)
        }
    }

    // MARK: - Background Layer Effects

    func setLayerVariableBlur(_ id: UUID, to newValue: VariableBlurConfiguration?, undoManager: UndoManager?) {
        guard let index = background.layers.firstIndex(where: { $0.id == id }) else { return }
        let oldValue = background.layers[index].variableBlur
        background.layers[index].variableBlur = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Variable Blur") { doc, um in
            doc.setLayerVariableBlur(id, to: oldValue, undoManager: um)
        }
    }

    func setLayerColorAdjustments(_ id: UUID, to newValue: ColorAdjustments?, undoManager: UndoManager?) {
        guard let index = background.layers.firstIndex(where: { $0.id == id }) else { return }
        let oldValue = background.layers[index].colorAdjustments
        background.layers[index].colorAdjustments = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Color Adjustments") { doc, um in
            doc.setLayerColorAdjustments(id, to: oldValue, undoManager: um)
        }
    }

    func setLayerVignette(_ id: UUID, to newValue: VignetteConfiguration?, undoManager: UndoManager?) {
        guard let index = background.layers.firstIndex(where: { $0.id == id }) else { return }
        let oldValue = background.layers[index].vignette
        background.layers[index].vignette = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Vignette") { doc, um in
            doc.setLayerVignette(id, to: oldValue, undoManager: um)
        }
    }

    func setLayerBloom(_ id: UUID, to newValue: BloomConfiguration?, undoManager: UndoManager?) {
        guard let index = background.layers.firstIndex(where: { $0.id == id }) else { return }
        let oldValue = background.layers[index].bloom
        background.layers[index].bloom = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Bloom") { doc, um in
            doc.setLayerBloom(id, to: oldValue, undoManager: um)
        }
    }

    // MARK: - Text Layer Management

    func addTextLayer(undoManager: UndoManager?) {
        let layer = TextLayerConfiguration(
            position: CGPoint(
                x: round(window.width / 2),
                y: round(window.height / 2)
            )
        )
        textLayers.append(layer)
        objectWillChange.send()
        withUndo(undoManager, "Add Text Layer") { doc, um in
            doc.removeTextLayer(layer.id, undoManager: um)
        }
    }

    func removeTextLayer(_ id: UUID, undoManager: UndoManager?) {
        guard let index = textLayers.firstIndex(where: { $0.id == id }) else { return }
        let removed = textLayers.remove(at: index)
        objectWillChange.send()
        withUndo(undoManager, "Remove Text Layer") { doc, um in
            doc.textLayers.insert(removed, at: min(index, doc.textLayers.count))
            doc.objectWillChange.send()
            doc.withUndo(um, "Add Text Layer") { doc, um in
                doc.removeTextLayer(id, undoManager: um)
            }
        }
    }

    func moveTextLayer(_ id: UUID, to newPosition: CGPoint, undoManager: UndoManager?) {
        guard let index = textLayers.firstIndex(where: { $0.id == id }) else { return }
        let oldPosition = textLayers[index].position
        let rounded = CGPoint(x: round(newPosition.x), y: round(newPosition.y))
        textLayers[index].position = rounded
        objectWillChange.send()
        withUndo(undoManager, "Move Text Layer") { doc, um in
            doc.moveTextLayer(id, to: oldPosition, undoManager: um)
        }
    }

    func setTextLayerText(_ id: UUID, to newText: String, undoManager: UndoManager?) {
        guard let index = textLayers.firstIndex(where: { $0.id == id }) else { return }
        let oldText = textLayers[index].text
        textLayers[index].text = newText
        objectWillChange.send()
        withUndo(undoManager, "Edit Text") { doc, um in
            doc.setTextLayerText(id, to: oldText, undoManager: um)
        }
    }

    func updateTextLayerStyle(
        _ id: UUID,
        with transform: (inout TextLayerConfiguration) -> Void,
        undoManager: UndoManager?
    ) {
        guard let index = textLayers.firstIndex(where: { $0.id == id }) else { return }
        let old = textLayers[index]
        transform(&textLayers[index])
        // Preserve identity fields
        textLayers[index].id = old.id
        textLayers[index].position = old.position
        objectWillChange.send()
        withUndo(undoManager, "Change Text Style") { doc, um in
            doc.updateTextLayerStyle(id, with: { $0 = old }, undoManager: um)
        }
    }

    // MARK: - SF Symbol Layer Management

    func addSFSymbolLayer(undoManager: UndoManager?) {
        addSFSymbolLayer(
            at: CGPoint(
                x: round(window.width / 2),
                y: round(window.height / 2)
            ),
            undoManager: undoManager
        )
    }

    func addSFSymbolLayer(at position: CGPoint, undoManager: UndoManager?) {
        let layer = SFSymbolLayerConfiguration(position: position)
        sfSymbolLayers.append(layer)
        objectWillChange.send()
        withUndo(undoManager, "Add Symbol Layer") { doc, um in
            doc.removeSFSymbolLayer(layer.id, undoManager: um)
        }
    }

    func removeSFSymbolLayer(_ id: UUID, undoManager: UndoManager?) {
        guard let index = sfSymbolLayers.firstIndex(where: { $0.id == id }) else { return }
        let removed = sfSymbolLayers.remove(at: index)
        objectWillChange.send()
        withUndo(undoManager, "Remove Symbol Layer") { doc, um in
            doc.sfSymbolLayers.insert(removed, at: min(index, doc.sfSymbolLayers.count))
            doc.objectWillChange.send()
            doc.withUndo(um, "Add Symbol Layer") { doc, um in
                doc.removeSFSymbolLayer(id, undoManager: um)
            }
        }
    }

    func moveSFSymbolLayer(_ id: UUID, to newPosition: CGPoint, undoManager: UndoManager?) {
        guard let index = sfSymbolLayers.firstIndex(where: { $0.id == id }) else { return }
        let oldPosition = sfSymbolLayers[index].position
        let rounded = CGPoint(x: round(newPosition.x), y: round(newPosition.y))
        sfSymbolLayers[index].position = rounded
        objectWillChange.send()
        withUndo(undoManager, "Move Symbol Layer") { doc, um in
            doc.moveSFSymbolLayer(id, to: oldPosition, undoManager: um)
        }
    }

    func updateSFSymbolLayerStyle(
        _ id: UUID,
        with transform: (inout SFSymbolLayerConfiguration) -> Void,
        undoManager: UndoManager?
    ) {
        guard let index = sfSymbolLayers.firstIndex(where: { $0.id == id }) else { return }
        let old = sfSymbolLayers[index]
        transform(&sfSymbolLayers[index])
        // Preserve identity fields
        sfSymbolLayers[index].id = old.id
        sfSymbolLayers[index].position = old.position
        objectWillChange.send()
        withUndo(undoManager, "Change Symbol Style") { doc, um in
            doc.updateSFSymbolLayerStyle(id, with: { $0 = old }, undoManager: um)
        }
    }
}
