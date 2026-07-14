import AppKit
@preconcurrency import Combine
import Foundation

extension RilmazafoneDocument {
    // MARK: - DMG Import

    /// Whether the document has never been saved and has no content — the
    /// case where a dropped DMG should populate this document rather than
    /// open a new one.
    var isUntitledAndEmpty: Bool {
        fileURL == nil
            && items.isEmpty
            && background.layers.isEmpty
            && textLayers.isEmpty
            && sfSymbolLayers.isEmpty
    }

    /// Creates a document pre-populated from a DMG import result.
    ///
    /// The deferred `objectWillChange` ping fires after SwiftUI attaches its
    /// change observation, so the imported (unsaved) content registers as an
    /// edit and closing the window prompts to save.
    convenience init(imported result: DMGImporter.Result) {
        self.init()
        applyImportedDMG(result)
        Task { [weak self] in
            self?.objectWillChange.send()
        }
    }

    /// Populates the document from a DMG import result: configuration, assets
    /// (background image, custom volume icon), their cached images, and the
    /// harvested app icons.
    func applyImportedDMG(_ result: DMGImporter.Result) {
        configuration = result.configuration

        if !result.assets.isEmpty {
            ensureAssetsWrapper()
            for (name, data) in result.assets {
                replaceAsset(named: name, with: data)
            }
        }

        backgroundImages.removeAll()
        for layer in background.layers {
            if let data = result.assets[layer.imageName] {
                backgroundImages[layer.id] = NSImage(data: data)
            }
        }

        if let iconName = volumeIcon.sourceIconName,
           let data = result.assets[iconName] {
            volumeIconImage = NSImage(data: data)
        }

        importedItemIcons = result.itemIcons.compactMapValues { NSImage(data: $0) }

        refreshSourceStates()
        objectWillChange.send()
    }

    /// Handles a `.dmg` dropped on the canvas: populates this document when it
    /// is untitled and empty, otherwise opens the import as a new document.
    func importDroppedDMG(from url: URL) async {
        guard let result = await DMGImportCoordinator.shared.runImport(from: url) else { return }
        if isUntitledAndEmpty {
            applyImportedDMG(result)
        } else {
            await DMGImportCoordinator.shared.openNewDocument(with: result)
        }
    }
}
