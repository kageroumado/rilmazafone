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
                x: configuration.window.width / 2,
                y: configuration.window.height / 2
            )
        )
        configuration.background.layers.append(layer)

        if let image = NSImage(data: data) {
            backgroundImages[layerID] = image
        }

        if configuration.background.type != .image {
            configuration.background.type = .image
        }

        objectWillChange.send()
        withUndo(undoManager, "Add Background Image") { doc, um in
            doc.removeBackgroundLayer(layerID, undoManager: um)
        }
    }

    func removeBackgroundLayer(_ id: UUID, undoManager: UndoManager?) {
        guard let index = configuration.background.layers.firstIndex(where: { $0.id == id }) else {
            return
        }
        let removed = configuration.background.layers.remove(at: index)
        let removedImage = backgroundImages.removeValue(forKey: id)

        if let wrapper = assetsWrapper?.fileWrappers?[removed.imageName] {
            assetsWrapper?.removeFileWrapper(wrapper)
        }

        if configuration.background.layers.isEmpty, configuration.background.type == .image {
            configuration.background.type = .color
        }

        objectWillChange.send()
        withUndo(undoManager, "Remove Background Image") { doc, um in
            doc.configuration.background.layers.insert(removed, at: min(index, doc.configuration.background.layers.count))
            if let img = removedImage {
                doc.backgroundImages[id] = img
            }
            if doc.configuration.background.type != .image {
                doc.configuration.background.type = .image
            }
            doc.objectWillChange.send()
            doc.withUndo(um, "Add Background Image") { doc, um in
                doc.removeBackgroundLayer(id, undoManager: um)
            }
        }
    }

    func moveBackgroundLayer(_ id: UUID, to newPosition: CGPoint, undoManager: UndoManager?) {
        guard let index = configuration.background.layers.firstIndex(where: { $0.id == id }) else {
            return
        }
        let oldPosition = configuration.background.layers[index].position
        let rounded = CGPoint(x: round(newPosition.x), y: round(newPosition.y))
        configuration.background.layers[index].position = rounded
        objectWillChange.send()
        withUndo(undoManager, "Move Background Image") { doc, um in
            doc.moveBackgroundLayer(id, to: oldPosition, undoManager: um)
        }
    }

    func setBackgroundLayerScale(_ id: UUID, to newScale: CGFloat, undoManager: UndoManager?) {
        guard let index = configuration.background.layers.firstIndex(where: { $0.id == id }) else {
            return
        }
        let oldScale = configuration.background.layers[index].scale
        configuration.background.layers[index].scale = newScale
        objectWillChange.send()
        withUndo(undoManager, "Scale Background Image") { doc, um in
            doc.setBackgroundLayerScale(id, to: oldScale, undoManager: um)
        }
    }

    func setBackgroundLayerBlur(_ id: UUID, to newBlur: CGFloat, undoManager: UndoManager?) {
        guard let index = configuration.background.layers.firstIndex(where: { $0.id == id }) else {
            return
        }
        let oldBlur = configuration.background.layers[index].blurRadius
        configuration.background.layers[index].blurRadius = newBlur
        objectWillChange.send()
        withUndo(undoManager, "Change Layer Blur") { doc, um in
            doc.setBackgroundLayerBlur(id, to: oldBlur, undoManager: um)
        }
    }

    // MARK: - Background Layer Effects

    func setLayerVariableBlur(_ id: UUID, to newValue: VariableBlurConfiguration?, undoManager: UndoManager?) {
        guard let index = configuration.background.layers.firstIndex(where: { $0.id == id }) else { return }
        let oldValue = configuration.background.layers[index].variableBlur
        configuration.background.layers[index].variableBlur = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Variable Blur") { doc, um in
            doc.setLayerVariableBlur(id, to: oldValue, undoManager: um)
        }
    }

    func setLayerColorAdjustments(_ id: UUID, to newValue: ColorAdjustments?, undoManager: UndoManager?) {
        guard let index = configuration.background.layers.firstIndex(where: { $0.id == id }) else { return }
        let oldValue = configuration.background.layers[index].colorAdjustments
        configuration.background.layers[index].colorAdjustments = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Color Adjustments") { doc, um in
            doc.setLayerColorAdjustments(id, to: oldValue, undoManager: um)
        }
    }

    func setLayerVignette(_ id: UUID, to newValue: VignetteConfiguration?, undoManager: UndoManager?) {
        guard let index = configuration.background.layers.firstIndex(where: { $0.id == id }) else { return }
        let oldValue = configuration.background.layers[index].vignette
        configuration.background.layers[index].vignette = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Vignette") { doc, um in
            doc.setLayerVignette(id, to: oldValue, undoManager: um)
        }
    }

    func setLayerBloom(_ id: UUID, to newValue: BloomConfiguration?, undoManager: UndoManager?) {
        guard let index = configuration.background.layers.firstIndex(where: { $0.id == id }) else { return }
        let oldValue = configuration.background.layers[index].bloom
        configuration.background.layers[index].bloom = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Bloom") { doc, um in
            doc.setLayerBloom(id, to: oldValue, undoManager: um)
        }
    }

    // MARK: - Text Layer Management

    func addTextLayer(undoManager: UndoManager?) {
        let layer = TextLayerConfiguration(
            position: CGPoint(
                x: round(configuration.window.width / 2),
                y: round(configuration.window.height / 2)
            )
        )
        configuration.textLayers.append(layer)
        objectWillChange.send()
        withUndo(undoManager, "Add Text Layer") { doc, um in
            doc.removeTextLayer(layer.id, undoManager: um)
        }
    }

    func removeTextLayer(_ id: UUID, undoManager: UndoManager?) {
        guard let index = configuration.textLayers.firstIndex(where: { $0.id == id }) else { return }
        let removed = configuration.textLayers.remove(at: index)
        objectWillChange.send()
        withUndo(undoManager, "Remove Text Layer") { doc, um in
            doc.configuration.textLayers.insert(removed, at: min(index, doc.configuration.textLayers.count))
            doc.objectWillChange.send()
            doc.withUndo(um, "Add Text Layer") { doc, um in
                doc.removeTextLayer(id, undoManager: um)
            }
        }
    }

    func moveTextLayer(_ id: UUID, to newPosition: CGPoint, undoManager: UndoManager?) {
        guard let index = configuration.textLayers.firstIndex(where: { $0.id == id }) else { return }
        let oldPosition = configuration.textLayers[index].position
        let rounded = CGPoint(x: round(newPosition.x), y: round(newPosition.y))
        configuration.textLayers[index].position = rounded
        objectWillChange.send()
        withUndo(undoManager, "Move Text Layer") { doc, um in
            doc.moveTextLayer(id, to: oldPosition, undoManager: um)
        }
    }

    func setTextLayerText(_ id: UUID, to newText: String, undoManager: UndoManager?) {
        guard let index = configuration.textLayers.firstIndex(where: { $0.id == id }) else { return }
        let oldText = configuration.textLayers[index].text
        configuration.textLayers[index].text = newText
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
        guard let index = configuration.textLayers.firstIndex(where: { $0.id == id }) else { return }
        let old = configuration.textLayers[index]
        transform(&configuration.textLayers[index])
        // Preserve identity fields
        configuration.textLayers[index].id = old.id
        configuration.textLayers[index].position = old.position
        objectWillChange.send()
        withUndo(undoManager, "Change Text Style") { doc, um in
            doc.updateTextLayerStyle(id, with: { $0 = old }, undoManager: um)
        }
    }

    // MARK: - SF Symbol Layer Management

    func addSFSymbolLayer(undoManager: UndoManager?) {
        addSFSymbolLayer(
            at: CGPoint(
                x: round(configuration.window.width / 2),
                y: round(configuration.window.height / 2)
            ),
            undoManager: undoManager
        )
    }

    func addSFSymbolLayer(at position: CGPoint, undoManager: UndoManager?) {
        let layer = SFSymbolLayerConfiguration(position: position)
        configuration.sfSymbolLayers.append(layer)
        objectWillChange.send()
        withUndo(undoManager, "Add Symbol Layer") { doc, um in
            doc.removeSFSymbolLayer(layer.id, undoManager: um)
        }
    }

    func removeSFSymbolLayer(_ id: UUID, undoManager: UndoManager?) {
        guard let index = configuration.sfSymbolLayers.firstIndex(where: { $0.id == id }) else { return }
        let removed = configuration.sfSymbolLayers.remove(at: index)
        objectWillChange.send()
        withUndo(undoManager, "Remove Symbol Layer") { doc, um in
            doc.configuration.sfSymbolLayers.insert(removed, at: min(index, doc.configuration.sfSymbolLayers.count))
            doc.objectWillChange.send()
            doc.withUndo(um, "Add Symbol Layer") { doc, um in
                doc.removeSFSymbolLayer(id, undoManager: um)
            }
        }
    }

    func moveSFSymbolLayer(_ id: UUID, to newPosition: CGPoint, undoManager: UndoManager?) {
        guard let index = configuration.sfSymbolLayers.firstIndex(where: { $0.id == id }) else { return }
        let oldPosition = configuration.sfSymbolLayers[index].position
        let rounded = CGPoint(x: round(newPosition.x), y: round(newPosition.y))
        configuration.sfSymbolLayers[index].position = rounded
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
        guard let index = configuration.sfSymbolLayers.firstIndex(where: { $0.id == id }) else { return }
        let old = configuration.sfSymbolLayers[index]
        transform(&configuration.sfSymbolLayers[index])
        // Preserve identity fields
        configuration.sfSymbolLayers[index].id = old.id
        configuration.sfSymbolLayers[index].position = old.position
        objectWillChange.send()
        withUndo(undoManager, "Change Symbol Style") { doc, um in
            doc.updateSFSymbolLayerStyle(id, with: { $0 = old }, undoManager: um)
        }
    }
}
