import AppKit
@preconcurrency import Combine
import Foundation
import SwiftUI

extension RilmazafoneDocument {
    // MARK: - Item Properties

    func setItemSourcePath(_ id: UUID, to newPath: String?, undoManager: UndoManager?) {
        setItemSource(id, path: newPath, bookmark: nil, actionName: "Change Source Path", undoManager: undoManager)
    }

    /// Sets an item's source path, security bookmark, and embedded-payload
    /// reference together, refreshing availability state. All source mutations
    /// funnel through here so undo restores every half atomically. Setting an
    /// external source clears `assetName` by default — pointing an embedded
    /// item at the filesystem replaces its embedded content (the payload stays
    /// in the document's assets, so undo restores a working embedded item).
    func setItemSource(
        _ id: UUID,
        path: String?,
        bookmark: Data?,
        assetName: String? = nil,
        actionName: String = "Change Source",
        undoManager: UndoManager?,
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let oldPath = items[index].sourcePath
        let oldBookmark = items[index].sourceBookmark
        let oldAssetName = items[index].assetName
        items[index].sourcePath = path
        items[index].sourceBookmark = bookmark
        items[index].assetName = assetName
        refreshSourceStates()
        objectWillChange.send()
        withUndo(undoManager, actionName) { doc, um in
            doc.setItemSource(
                id,
                path: oldPath,
                bookmark: oldBookmark,
                assetName: oldAssetName,
                actionName: actionName,
                undoManager: um,
            )
        }
    }

    /// Relinks an item to a freshly user-selected source URL: refreshes the path,
    /// re-creates the security bookmark (App Store build), recomputes availability,
    /// and re-runs signing detection for app items. Undoable as a single action.
    func relinkItem(_ id: UUID, to url: URL, undoManager: UndoManager?) async {
        setItemSource(
            id,
            path: url.path,
            bookmark: SourceAccess.makeBookmark(for: url, documentURL: fileURL),
            actionName: "Relink Item",
            undoManager: undoManager,
        )
        guard let item = items.first(where: { $0.id == id }),
              item.kind == .app else { return }
        await configureCodeSigning(for: item, undoManager: undoManager)
    }

    func setItemLinkType(_ id: UUID, to newType: ItemLinkType, undoManager: UndoManager?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let oldType = items[index].linkType
        items[index].linkType = newType
        objectWillChange.send()
        withUndo(undoManager, "Change Link Type") { doc, um in
            doc.setItemLinkType(id, to: oldType, undoManager: um)
        }
    }

    // MARK: - Item Background

    func setItemBackground(_ id: UUID, to background: ItemBackground?, undoManager: UndoManager?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let oldBackground = items[index].background
        items[index].background = background
        objectWillChange.send()
        withUndo(undoManager, background != nil ? "Add Item Background" : "Remove Item Background") { doc, um in
            doc.setItemBackground(id, to: oldBackground, undoManager: um)
        }
    }

    func updateItemBackground(
        _ id: UUID,
        with transform: (inout ItemBackground) -> Void,
        undoManager: UndoManager?,
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let old = items[index].background else { return }
        var updated = old
        transform(&updated)
        items[index].background = updated
        objectWillChange.send()
        withUndo(undoManager, "Change Item Background") { doc, um in
            doc.setItemBackground(id, to: old, undoManager: um)
        }
    }

    // MARK: - Item CRUD

    func moveItem(_ id: UUID, to newPosition: CGPoint, undoManager: UndoManager?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let oldPosition = items[index].position
        items[index].position = newPosition
        objectWillChange.send()
        withUndo(undoManager, "Move Item") { doc, um in
            doc.moveItem(id, to: oldPosition, undoManager: um)
        }
    }

    func addItem(_ item: CanvasItem, undoManager: UndoManager?) {
        items.append(item)
        refreshSourceStates()
        objectWillChange.send()
        withUndo(undoManager, "Add \(item.label)") { doc, um in
            doc.removeItem(item.id, undoManager: um)
        }
    }

    func removeItem(_ id: UUID, undoManager: UndoManager?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: index)
        refreshSourceStates()
        objectWillChange.send()
        withUndo(undoManager, "Remove \(removed.label)") { doc, um in
            doc.items.insert(removed, at: min(index, doc.items.count))
            doc.refreshSourceStates()
            doc.objectWillChange.send()
            doc.withUndo(um, "Add \(removed.label)") { doc, um in
                doc.removeItem(id, undoManager: um)
            }
        }
    }

    func setItemLabel(_ id: UUID, to newLabel: String, undoManager: UndoManager?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let oldLabel = items[index].label
        items[index].label = newLabel
        objectWillChange.send()
        withUndo(undoManager, "Rename Item") { doc, um in
            doc.setItemLabel(id, to: oldLabel, undoManager: um)
        }
    }

    func moveItemInList(from source: IndexSet, to destination: Int, undoManager: UndoManager?) {
        let oldItems = items
        items.move(fromOffsets: source, toOffset: destination)
        objectWillChange.send()
        withUndo(undoManager, "Reorder Items") { doc, um in
            doc.items = oldItems
            doc.objectWillChange.send()
            doc.withUndo(um, "Reorder Items") { doc, um in
                doc.moveItemInList(from: source, to: destination, undoManager: um)
            }
        }
    }

    // MARK: - Item Shadow, Bevel & Enabled

    func setItemShadow(_ id: UUID, to newValue: ShadowConfiguration?, undoManager: UndoManager?) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              var bg = items[index].background else { return }
        let oldValue = bg.shadow
        bg.shadow = newValue
        items[index].background = bg
        objectWillChange.send()
        withUndo(undoManager, newValue != nil ? "Add Shadow" : "Remove Shadow") { doc, um in
            doc.setItemShadow(id, to: oldValue, undoManager: um)
        }
    }

    func setItemBevel(_ id: UUID, to newValue: BevelConfiguration?, undoManager: UndoManager?) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              var bg = items[index].background else { return }
        let oldValue = bg.bevel
        bg.bevel = newValue
        items[index].background = bg
        objectWillChange.send()
        withUndo(undoManager, newValue != nil ? "Add Bevel" : "Remove Bevel") { doc, um in
            doc.setItemBevel(id, to: oldValue, undoManager: um)
        }
    }

    func setItemBackgroundEnabled(_ id: UUID, _ enabled: Bool, undoManager: UndoManager?) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              var bg = items[index].background else { return }
        let oldEnabled = bg.enabled
        guard oldEnabled != enabled else { return }
        bg.enabled = enabled
        items[index].background = bg
        objectWillChange.send()
        withUndo(undoManager, enabled ? "Enable Item Background" : "Disable Item Background") { doc, um in
            doc.setItemBackgroundEnabled(id, oldEnabled, undoManager: um)
        }
    }

    func copyItemBackgroundToAll(_ sourceID: UUID, undoManager: UndoManager?) {
        guard let sourceItem = items.first(where: { $0.id == sourceID }),
              let sourceBg = sourceItem.background else { return }
        let otherIndices = items.indices.filter { items[$0].id != sourceID }
        guard !otherIndices.isEmpty else { return }

        let oldBackgrounds: [(UUID, ItemBackground?)] = otherIndices.map {
            (items[$0].id, items[$0].background)
        }
        for i in otherIndices {
            items[i].background = sourceBg
        }
        objectWillChange.send()

        withUndo(undoManager, "Copy Background to All Items") { doc, um in
            for (id, bg) in oldBackgrounds {
                guard let idx = doc.items.firstIndex(where: { $0.id == id }) else { continue }
                doc.items[idx].background = bg
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
        let labelHalf = (iconSize + 40) / 2
        if let bg = item.background, bg.enabled {
            let bgHalf = (iconSize + 44) / 2 + bg.padding
            return max(labelHalf, bgHalf)
        }
        return labelHalf
    }

    /// Half-height of an item's visual extent from its center point.
    /// The tallest element is either the VStack (icon cell + text gap + text)
    /// or the background square when present.
    private func itemHalfHeight(_ item: CanvasItem) -> CGFloat {
        let vStackHalf = (iconSize + 28 + textSize) / 2
        if let bg = item.background, bg.enabled {
            let bgHalf = (iconSize + 44) / 2 + bg.padding
            return max(vStackHalf, bgHalf)
        }
        return vStackHalf
    }

    func distributeItemsHorizontally(undoManager: UndoManager?) {
        let items = self.items
        guard items.count >= 2 else { return }

        let oldPositions = items.map { ($0.id, $0.position) }
        let sorted = items.sorted { $0.position.x < $1.position.x }
        let halfWidths = sorted.map { itemHalfWidth($0) }
        let totalItemWidth = halfWidths.reduce(0, +) * 2
        let gap = max((window.width - totalItemWidth) / CGFloat(sorted.count + 1), 0)

        var x = gap
        for (i, item) in sorted.enumerated() {
            x += halfWidths[i]
            guard let index = self.items.firstIndex(where: { $0.id == item.id }) else { continue }
            self.items[index].position.x = round(x)
            x += halfWidths[i] + gap
        }
        objectWillChange.send()

        withUndo(undoManager, "Distribute Horizontally") { doc, um in
            for (id, pos) in oldPositions {
                guard let idx = doc.items.firstIndex(where: { $0.id == id }) else { continue }
                doc.items[idx].position = pos
            }
            doc.objectWillChange.send()
            doc.withUndo(um, "Distribute Horizontally") { doc, um in
                doc.distributeItemsHorizontally(undoManager: um)
            }
        }
    }

    func distributeItemsVertically(undoManager: UndoManager?) {
        let items = self.items
        guard items.count >= 2 else { return }

        let oldPositions = items.map { ($0.id, $0.position) }
        let sorted = items.sorted { $0.position.y < $1.position.y }
        let halfHeights = sorted.map { itemHalfHeight($0) }
        let totalItemHeight = halfHeights.reduce(0, +) * 2
        let gap = max((window.height - totalItemHeight) / CGFloat(sorted.count + 1), 0)

        var y = gap
        for (i, item) in sorted.enumerated() {
            y += halfHeights[i]
            guard let index = self.items.firstIndex(where: { $0.id == item.id }) else { continue }
            self.items[index].position.y = round(y)
            y += halfHeights[i] + gap
        }
        objectWillChange.send()

        withUndo(undoManager, "Distribute Vertically") { doc, um in
            for (id, pos) in oldPositions {
                guard let idx = doc.items.firstIndex(where: { $0.id == id }) else { continue }
                doc.items[idx].position = pos
            }
            doc.objectWillChange.send()
            doc.withUndo(um, "Distribute Vertically") { doc, um in
                doc.distributeItemsVertically(undoManager: um)
            }
        }
    }

    func centerItemsVertically(undoManager: UndoManager?) {
        let items = self.items
        guard !items.isEmpty else { return }

        // Slight upward bias (47%) for optical center — title bar weight
        let centerY = round(window.height * 0.47)
        let oldPositions = items.map { ($0.id, $0.position) }

        for i in items.indices {
            self.items[i].position.y = centerY
        }
        objectWillChange.send()

        withUndo(undoManager, "Center Vertically") { doc, um in
            for (id, pos) in oldPositions {
                guard let idx = doc.items.firstIndex(where: { $0.id == id }) else { continue }
                doc.items[idx].position = pos
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
            sourceBookmark: SourceAccess.makeBookmark(for: url, documentURL: fileURL),
            position: position,
        )
        addItem(item, undoManager: undoManager)

        if isFirstApp {
            let name = url.deletingPathExtension().lastPathComponent
            setVolumeName(name, undoManager: undoManager)

            let width = window.width
            let appX = position.x
            let symlinkX = round(width - appX)
            let centerY = position.y

            let hasSymlink = items.contains { $0.kind == .applicationsSymlink }
            if !hasSymlink {
                let symlink = CanvasItem(
                    kind: .applicationsSymlink,
                    label: "Applications",
                    position: CGPoint(x: symlinkX, y: centerY),
                )
                addItem(symlink, undoManager: undoManager)
            }

            let arrowX = round((appX + symlinkX) / 2)
            addSFSymbolLayer(at: CGPoint(x: arrowX, y: centerY), undoManager: undoManager)

            await configureCodeSigning(for: item, undoManager: undoManager)
        }
    }

    /// Adds a file or folder item sourced from a user-selected URL, creating its
    /// security bookmark in the App Store build.
    func addFileItem(from url: URL, at position: CGPoint, undoManager: UndoManager?) {
        let item = CanvasItem(
            kind: url.hasDirectoryPath ? .folder : .file,
            label: url.lastPathComponent,
            sourcePath: url.path,
            sourceBookmark: SourceAccess.makeBookmark(for: url, documentURL: fileURL),
            position: position,
        )
        addItem(item, undoManager: undoManager)
    }

    /// The first unfilled placeholder of the given kind, if any — the slot a
    /// dropped source of that kind fills.
    func firstPlaceholderID(ofKind kind: CanvasItemKind) -> UUID? {
        items.first { $0.isPlaceholder && $0.kind == kind }?.id
    }

    /// Fills a placeholder in place from a dropped source of its own kind (app,
    /// folder, or file): swaps in the source's name, path, security bookmark, and
    /// — for app slots — the detected signing identity, then clears the
    /// placeholder flag, preserving the slot's position and identity. The whole
    /// substitution is a single undoable action, so one undo restores the
    /// placeholder (and any prior signing configuration).
    func fillPlaceholder(_ id: UUID, from url: URL, undoManager: UndoManager?) async {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].isPlaceholder else { return }

        let oldItem = items[index]
        let oldCodeSign = codeSign

        var filledItem = oldItem
        filledItem.label = url.lastPathComponent
        filledItem.sourcePath = url.path
        filledItem.sourceBookmark = SourceAccess.makeBookmark(for: url, documentURL: fileURL)
        filledItem.assetName = nil
        filledItem.isPlaceholder = false

        // Signing detection only applies to apps; a filled folder/file slot
        // never touches the document's code-signing configuration.
        var newCodeSign = oldCodeSign
        if oldItem.kind == .app, let identity = await detectedSigningIdentity(for: filledItem) {
            newCodeSign.enabled = true
            newCodeSign.identity = identity
        }

        swapPlaceholderState(
            id,
            toItem: filledItem, toCodeSign: newCodeSign,
            fromItem: oldItem, fromCodeSign: oldCodeSign,
            actionName: Self.fillActionName(for: oldItem.kind),
            undoManager: undoManager,
        )
    }

    /// Undo/redo action name for filling a placeholder of the given kind.
    private static func fillActionName(for kind: CanvasItemKind) -> String {
        switch kind {
        case .folder: "Fill Folder Slot"
        case .file: "Fill File Slot"
        default: "Fill App Placeholder"
        }
    }

    /// Atomically swaps an item and the document's signing configuration to a
    /// target state, registering the inverse swap for undo. Both the fill and
    /// its undo/redo run through here so the placeholder round-trips exactly.
    private func swapPlaceholderState(
        _ id: UUID,
        toItem: CanvasItem,
        toCodeSign: CodeSignConfiguration,
        fromItem: CanvasItem,
        fromCodeSign: CodeSignConfiguration,
        actionName: String,
        undoManager: UndoManager?,
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index] = toItem
        codeSign = toCodeSign
        refreshSourceStates()
        objectWillChange.send()
        withUndo(undoManager, actionName) { doc, um in
            doc.swapPlaceholderState(
                id,
                toItem: fromItem, toCodeSign: fromCodeSign,
                fromItem: toItem, fromCodeSign: toCodeSign,
                actionName: actionName,
                undoManager: um,
            )
        }
    }

    /// Detects the keychain signing identity matching an app source's signature,
    /// reading under security scope so it works for bookmark-backed sources in
    /// the sandboxed build. Returns `nil` when the app is unsigned or no matching
    /// identity is installed.
    private func detectedSigningIdentity(for item: CanvasItem) async -> String? {
        let authority = SourceAccess.withScope(item: item, documentURL: fileURL) { url in
            url.flatMap { DMGBuilder.signingAuthority(of: $0) }
        }
        guard let authority else { return nil }
        return DMGBuilder.findMatchingKeychainIdentity(authority: authority)
    }

    func handleDrop(urls: [URL], defaultPosition: CGPoint, undoManager: UndoManager?) async {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "app" {
                if let placeholderID = firstPlaceholderID(ofKind: .app) {
                    await fillPlaceholder(placeholderID, from: url, undoManager: undoManager)
                } else {
                    let width = window.width
                    let appX = round((2 * width - iconSize) / 6)
                    let centerY = round(window.height / 2)
                    await addApp(from: url, at: CGPoint(x: appX, y: centerY), undoManager: undoManager)
                }
            } else if ["png", "jpg", "jpeg", "tiff"].contains(ext) {
                try? importBackgroundImage(from: url, undoManager: undoManager)
            } else if ext == "dmg" {
                await importDroppedDMG(from: url)
            } else {
                // Folders fill a folder slot, other files fill a file slot; each
                // falls back to a normal add when no matching-kind slot is open.
                let kind: CanvasItemKind = url.hasDirectoryPath ? .folder : .file
                if let placeholderID = firstPlaceholderID(ofKind: kind) {
                    await fillPlaceholder(placeholderID, from: url, undoManager: undoManager)
                } else {
                    addFileItem(from: url, at: defaultPosition, undoManager: undoManager)
                }
            }
        }
    }
}
