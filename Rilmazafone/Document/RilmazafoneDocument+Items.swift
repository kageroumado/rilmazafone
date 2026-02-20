import AppKit
@preconcurrency import Combine
import Foundation
import SwiftUI

extension RilmazafoneDocument {
    // MARK: - Item Properties

    func setItemSourcePath(_ id: UUID, to newPath: String?, undoManager: UndoManager?) {
        guard let index = configuration.items.firstIndex(where: { $0.id == id }) else { return }
        let oldPath = configuration.items[index].sourcePath
        configuration.items[index].sourcePath = newPath
        objectWillChange.send()
        withUndo(undoManager, "Change Source Path") { doc, um in
            doc.setItemSourcePath(id, to: oldPath, undoManager: um)
        }
    }

    func setItemLinkType(_ id: UUID, to newType: ItemLinkType, undoManager: UndoManager?) {
        guard let index = configuration.items.firstIndex(where: { $0.id == id }) else { return }
        let oldType = configuration.items[index].linkType
        configuration.items[index].linkType = newType
        objectWillChange.send()
        withUndo(undoManager, "Change Link Type") { doc, um in
            doc.setItemLinkType(id, to: oldType, undoManager: um)
        }
    }

    // MARK: - Item Background

    func setItemBackground(_ id: UUID, to background: ItemBackground?, undoManager: UndoManager?) {
        guard let index = configuration.items.firstIndex(where: { $0.id == id }) else { return }
        let oldBackground = configuration.items[index].background
        configuration.items[index].background = background
        objectWillChange.send()
        withUndo(undoManager, background != nil ? "Add Item Background" : "Remove Item Background") { doc, um in
            doc.setItemBackground(id, to: oldBackground, undoManager: um)
        }
    }

    func updateItemBackground(
        _ id: UUID,
        with transform: (inout ItemBackground) -> Void,
        undoManager: UndoManager?
    ) {
        guard let index = configuration.items.firstIndex(where: { $0.id == id }),
              let old = configuration.items[index].background else { return }
        var updated = old
        transform(&updated)
        configuration.items[index].background = updated
        objectWillChange.send()
        withUndo(undoManager, "Change Item Background") { doc, um in
            doc.setItemBackground(id, to: old, undoManager: um)
        }
    }

    // MARK: - Item CRUD

    func moveItem(_ id: UUID, to newPosition: CGPoint, undoManager: UndoManager?) {
        guard let index = configuration.items.firstIndex(where: { $0.id == id }) else { return }
        let oldPosition = configuration.items[index].position
        configuration.items[index].position = newPosition
        objectWillChange.send()
        withUndo(undoManager, "Move Item") { doc, um in
            doc.moveItem(id, to: oldPosition, undoManager: um)
        }
    }

    func addItem(_ item: CanvasItem, undoManager: UndoManager?) {
        configuration.items.append(item)
        objectWillChange.send()
        withUndo(undoManager, "Add \(item.label)") { doc, um in
            doc.removeItem(item.id, undoManager: um)
        }
    }

    func removeItem(_ id: UUID, undoManager: UndoManager?) {
        guard let index = configuration.items.firstIndex(where: { $0.id == id }) else { return }
        let removed = configuration.items.remove(at: index)
        objectWillChange.send()
        withUndo(undoManager, "Remove \(removed.label)") { doc, um in
            doc.configuration.items.insert(removed, at: min(index, doc.configuration.items.count))
            doc.objectWillChange.send()
            doc.withUndo(um, "Add \(removed.label)") { doc, um in
                doc.removeItem(id, undoManager: um)
            }
        }
    }

    func setItemLabel(_ id: UUID, to newLabel: String, undoManager: UndoManager?) {
        guard let index = configuration.items.firstIndex(where: { $0.id == id }) else { return }
        let oldLabel = configuration.items[index].label
        configuration.items[index].label = newLabel
        objectWillChange.send()
        withUndo(undoManager, "Rename Item") { doc, um in
            doc.setItemLabel(id, to: oldLabel, undoManager: um)
        }
    }

    func moveItemInList(from source: IndexSet, to destination: Int, undoManager: UndoManager?) {
        let oldItems = configuration.items
        configuration.items.move(fromOffsets: source, toOffset: destination)
        objectWillChange.send()
        withUndo(undoManager, "Reorder Items") { doc, um in
            doc.configuration.items = oldItems
            doc.objectWillChange.send()
            doc.withUndo(um, "Reorder Items") { doc, um in
                doc.moveItemInList(from: source, to: destination, undoManager: um)
            }
        }
    }

    // MARK: - Item Shadow, Bevel & Enabled

    func setItemShadow(_ id: UUID, to newValue: ShadowConfiguration?, undoManager: UndoManager?) {
        guard let index = configuration.items.firstIndex(where: { $0.id == id }),
              var bg = configuration.items[index].background else { return }
        let oldValue = bg.shadow
        bg.shadow = newValue
        configuration.items[index].background = bg
        objectWillChange.send()
        withUndo(undoManager, newValue != nil ? "Add Shadow" : "Remove Shadow") { doc, um in
            doc.setItemShadow(id, to: oldValue, undoManager: um)
        }
    }

    func setItemBevel(_ id: UUID, to newValue: BevelConfiguration?, undoManager: UndoManager?) {
        guard let index = configuration.items.firstIndex(where: { $0.id == id }),
              var bg = configuration.items[index].background else { return }
        let oldValue = bg.bevel
        bg.bevel = newValue
        configuration.items[index].background = bg
        objectWillChange.send()
        withUndo(undoManager, newValue != nil ? "Add Bevel" : "Remove Bevel") { doc, um in
            doc.setItemBevel(id, to: oldValue, undoManager: um)
        }
    }

    func setItemBackgroundEnabled(_ id: UUID, _ enabled: Bool, undoManager: UndoManager?) {
        guard let index = configuration.items.firstIndex(where: { $0.id == id }),
              var bg = configuration.items[index].background else { return }
        let oldEnabled = bg.enabled
        guard oldEnabled != enabled else { return }
        bg.enabled = enabled
        configuration.items[index].background = bg
        objectWillChange.send()
        withUndo(undoManager, enabled ? "Enable Item Background" : "Disable Item Background") { doc, um in
            doc.setItemBackgroundEnabled(id, oldEnabled, undoManager: um)
        }
    }

    func copyItemBackgroundToAll(_ sourceID: UUID, undoManager: UndoManager?) {
        guard let sourceItem = configuration.items.first(where: { $0.id == sourceID }),
              let sourceBg = sourceItem.background else { return }
        let otherIndices = configuration.items.indices.filter { configuration.items[$0].id != sourceID }
        guard !otherIndices.isEmpty else { return }

        let oldBackgrounds: [(UUID, ItemBackground?)] = otherIndices.map {
            (configuration.items[$0].id, configuration.items[$0].background)
        }
        for i in otherIndices {
            configuration.items[i].background = sourceBg
        }
        objectWillChange.send()

        withUndo(undoManager, "Copy Background to All Items") { doc, um in
            for (id, bg) in oldBackgrounds {
                guard let idx = doc.configuration.items.firstIndex(where: { $0.id == id }) else { continue }
                doc.configuration.items[idx].background = bg
            }
            doc.objectWillChange.send()
            doc.withUndo(um, "Copy Background to All Items") { doc, um in
                doc.copyItemBackgroundToAll(sourceID, undoManager: um)
            }
        }
    }

    // MARK: - Distribution

    /// Half-width of an item's visual extent from its center point.
    /// The widest element is either the label (maxLabelWidth = iconSize + 40)
    /// or the background square (iconSize + 44 + 2*padding) when present.
    private func itemHalfWidth(_ item: CanvasItem) -> CGFloat {
        let labelHalf = (configuration.iconSize + 40) / 2
        if let bg = item.background, bg.enabled {
            let bgHalf = (configuration.iconSize + 44) / 2 + bg.padding
            return max(labelHalf, bgHalf)
        }
        return labelHalf
    }

    /// Half-height of an item's visual extent from its center point.
    /// The tallest element is either the VStack (icon cell + text gap + text)
    /// or the background square when present.
    private func itemHalfHeight(_ item: CanvasItem) -> CGFloat {
        let vStackHalf = (configuration.iconSize + 28 + configuration.textSize) / 2
        if let bg = item.background, bg.enabled {
            let bgHalf = (configuration.iconSize + 44) / 2 + bg.padding
            return max(vStackHalf, bgHalf)
        }
        return vStackHalf
    }

    func distributeItemsHorizontally(undoManager: UndoManager?) {
        let items = configuration.items
        guard items.count >= 2 else { return }

        let oldPositions = items.map { ($0.id, $0.position) }
        let sorted = items.sorted { $0.position.x < $1.position.x }
        let halfWidths = sorted.map { itemHalfWidth($0) }
        let totalItemWidth = halfWidths.reduce(0, +) * 2
        let gap = max((configuration.window.width - totalItemWidth) / CGFloat(sorted.count + 1), 0)

        var x = gap
        for (i, item) in sorted.enumerated() {
            x += halfWidths[i]
            guard let index = configuration.items.firstIndex(where: { $0.id == item.id }) else { continue }
            configuration.items[index].position.x = round(x)
            x += halfWidths[i] + gap
        }
        objectWillChange.send()

        withUndo(undoManager, "Distribute Horizontally") { doc, um in
            for (id, pos) in oldPositions {
                guard let idx = doc.configuration.items.firstIndex(where: { $0.id == id }) else { continue }
                doc.configuration.items[idx].position = pos
            }
            doc.objectWillChange.send()
            doc.withUndo(um, "Distribute Horizontally") { doc, um in
                doc.distributeItemsHorizontally(undoManager: um)
            }
        }
    }

    func distributeItemsVertically(undoManager: UndoManager?) {
        let items = configuration.items
        guard items.count >= 2 else { return }

        let oldPositions = items.map { ($0.id, $0.position) }
        let sorted = items.sorted { $0.position.y < $1.position.y }
        let halfHeights = sorted.map { itemHalfHeight($0) }
        let totalItemHeight = halfHeights.reduce(0, +) * 2
        let gap = max((configuration.window.height - totalItemHeight) / CGFloat(sorted.count + 1), 0)

        var y = gap
        for (i, item) in sorted.enumerated() {
            y += halfHeights[i]
            guard let index = configuration.items.firstIndex(where: { $0.id == item.id }) else { continue }
            configuration.items[index].position.y = round(y)
            y += halfHeights[i] + gap
        }
        objectWillChange.send()

        withUndo(undoManager, "Distribute Vertically") { doc, um in
            for (id, pos) in oldPositions {
                guard let idx = doc.configuration.items.firstIndex(where: { $0.id == id }) else { continue }
                doc.configuration.items[idx].position = pos
            }
            doc.objectWillChange.send()
            doc.withUndo(um, "Distribute Vertically") { doc, um in
                doc.distributeItemsVertically(undoManager: um)
            }
        }
    }

    func centerItemsVertically(undoManager: UndoManager?) {
        let items = configuration.items
        guard !items.isEmpty else { return }

        // Slight upward bias (47%) for optical center — title bar weight
        let centerY = round(configuration.window.height * 0.47)
        let oldPositions = items.map { ($0.id, $0.position) }

        for i in configuration.items.indices {
            configuration.items[i].position.y = centerY
        }
        objectWillChange.send()

        withUndo(undoManager, "Center Vertically") { doc, um in
            for (id, pos) in oldPositions {
                guard let idx = doc.configuration.items.firstIndex(where: { $0.id == id }) else { continue }
                doc.configuration.items[idx].position = pos
            }
            doc.objectWillChange.send()
            doc.withUndo(um, "Center Vertically") { doc, um in
                doc.centerItemsVertically(undoManager: um)
            }
        }
    }

    // MARK: - Drop Handling

    func addApp(from url: URL, at position: CGPoint, undoManager: UndoManager?) async {
        let isFirstApp = !hasApp

        let item = CanvasItem(
            kind: .app,
            label: url.lastPathComponent,
            sourcePath: url.path,
            position: position
        )
        addItem(item, undoManager: undoManager)

        if isFirstApp {
            let name = url.deletingPathExtension().lastPathComponent
            setVolumeName(name, undoManager: undoManager)

            let width = configuration.window.width
            let appX = position.x
            let symlinkX = round(width - appX)
            let centerY = position.y

            let hasSymlink = configuration.items.contains { $0.kind == .applicationsSymlink }
            if !hasSymlink {
                let symlink = CanvasItem(
                    kind: .applicationsSymlink,
                    label: "Applications",
                    position: CGPoint(x: symlinkX, y: centerY)
                )
                addItem(symlink, undoManager: undoManager)
            }

            let arrowX = round((appX + symlinkX) / 2)
            addSFSymbolLayer(at: CGPoint(x: arrowX, y: centerY), undoManager: undoManager)

            await configureCodeSigning(forAppAt: url.path, undoManager: undoManager)
        }
    }

    func handleDrop(urls: [URL], defaultPosition: CGPoint, undoManager: UndoManager?) async {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "app" {
                let width = configuration.window.width
                let appX = round((2 * width - configuration.iconSize) / 6)
                let centerY = round(configuration.window.height / 2)
                await addApp(from: url, at: CGPoint(x: appX, y: centerY), undoManager: undoManager)
            } else if ["png", "jpg", "jpeg", "tiff"].contains(ext) {
                try? importBackgroundImage(from: url, undoManager: undoManager)
            } else {
                let item = CanvasItem(
                    kind: url.hasDirectoryPath ? .folder : .file,
                    label: url.lastPathComponent,
                    sourcePath: url.path,
                    position: defaultPosition
                )
                addItem(item, undoManager: undoManager)
            }
        }
    }
}
