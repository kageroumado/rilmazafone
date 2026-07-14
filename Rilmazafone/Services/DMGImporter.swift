import CoreGraphics
import Foundation

/// Reconstructs a document configuration from an existing disk image's layout.
///
/// The importer mounts the image read-only, classifies the volume's root
/// entries into canvas items, reads the Finder view state from `.DS_Store`
/// (via ``DSStoreReader``), resolves the background image (via
/// ``AliasRecordReader``), and copies everything the document needs out of the
/// volume before detaching — the volume is always detached, on success,
/// failure, and cancellation.
///
/// The result is layout only: items whose payload lived inside the DMG import
/// with `sourcePath: nil` and surface the missing-source badge until relinked.
///
/// Coordinate mapping inverts ``DSStoreWriter`` exactly: `Iloc` y-values gain
/// ``DSStoreWriter/finderContentInset`` back, and the `bwsp` window frame
/// loses ``DSStoreWriter/finderTitleBarHeight`` to recover the content-area
/// height the canvas designs for.
nonisolated enum DMGImporter {
    // MARK: - Result

    /// Everything harvested from a mounted DMG, ready to populate a document.
    struct Result: Sendable {
        /// The reconstructed configuration (items, window, view settings,
        /// background, volume icon).
        var configuration: DMGConfiguration

        /// Asset payloads keyed by the asset filename referenced from
        /// `configuration` — the background image layer and, when present,
        /// the custom volume icon.
        var assets: [String: Data] = [:]

        /// Raw `.icns` app icons harvested while the volume was mounted,
        /// keyed by canvas item ID, so the canvas can show the real icon even
        /// though the item's in-DMG source is unreachable after detach.
        var itemIcons: [UUID: Data] = [:]
    }

    enum ImportError: Error, LocalizedError {
        /// `hdiutil` could not attach the file as a disk image.
        case attachFailed(String)

        var errorDescription: String? {
            switch self {
            case let .attachFailed(detail):
                detail.isEmpty
                    ? "The file could not be opened as a disk image."
                    : "The file could not be opened as a disk image: \(detail)"
            }
        }
    }

    // MARK: - Constants

    private enum Defaults {
        static let minimumWindowWidth: CGFloat = 320
        static let minimumWindowHeight: CGFloat = 200
        static let iconSizeRange: ClosedRange<CGFloat> = 16 ... 512
        static let textSizeRange: ClosedRange<CGFloat> = 10 ... 16
        static let gridSpacingRange: ClosedRange<CGFloat> = 1 ... 100
        /// HFS+ volume name limit, matching build-time validation.
        static let volumeNameLimit = 27
        static let volumeIconAssetName = "volume-icon.icns"
    }

    /// Root entries that are Finder/DMG plumbing rather than content,
    /// compared case-insensitively.
    private static let housekeepingNames: Set<String> = [
        ".ds_store", ".background", ".bg", ".volumeicon.icns",
        ".trashes", ".fseventsd", ".temporaryitems", ".apdisk",
    ]

    // MARK: - Import

    /// Imports the layout of the disk image at `dmgURL`.
    ///
    /// - Returns: The reconstructed configuration plus every asset copied out
    ///   of the volume (background image, volume icon, app icons).
    /// - Throws: ``ImportError/attachFailed(_:)`` when the file is not a
    ///   mountable disk image; `CancellationError` when the surrounding task
    ///   is cancelled. The volume is detached on every exit path.
    static func importLayout(of dmgURL: URL) async throws -> Result {
        let mountPoint: URL
        do {
            mountPoint = try await DMGBuilder.attachReadOnly(dmgURL)
        } catch let error as ProcessRunner.ProcessError {
            throw ImportError.attachFailed(
                error.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        defer { try? FileManager.default.removeItem(at: mountPoint) }

        do {
            let result = try harvest(mountPoint: mountPoint, dmgURL: dmgURL)
            try await DMGBuilder.detach(mountPoint)
            return result
        } catch {
            try? await DMGBuilder.detach(mountPoint)
            throw error
        }
    }

    // MARK: - Harvest

    /// Reads everything the document needs while the volume is mounted.
    private static func harvest(mountPoint: URL, dmgURL: URL) throws -> Result {
        var configuration = DMGConfiguration()
        var assets: [String: Data] = [:]

        configuration.volumeName = volumeName(of: mountPoint, dmgURL: dmgURL)

        let dsStore = readDSStore(at: mountPoint)
        applyViewSettings(dsStore, to: &configuration)
        try Task.checkCancellation()

        let background = resolveBackground(dsStore: dsStore, mountPoint: mountPoint)
        applyBackground(background, dsStore: dsStore, to: &configuration, assets: &assets)
        try Task.checkCancellation()

        var items = try classifyRootItems(
            at: mountPoint,
            excludingDirectory: background?.rootDirectoryName
        )
        assignPositions(to: &items, dsStore: dsStore, window: configuration.window)
        configuration.items = items
        try Task.checkCancellation()

        if let iconData = try? Data(
            contentsOf: mountPoint.appending(path: ".VolumeIcon.icns")
        ) {
            configuration.volumeIcon = VolumeIconConfiguration(
                type: .custom,
                sourceIconName: Defaults.volumeIconAssetName
            )
            assets[Defaults.volumeIconAssetName] = iconData
        }

        return Result(
            configuration: configuration,
            assets: assets,
            itemIcons: harvestAppIcons(for: configuration.items, mountPoint: mountPoint)
        )
    }

    // MARK: - Volume Name

    private static func volumeName(of mountPoint: URL, dmgURL: URL) -> String {
        let resourceName = try? mountPoint
            .resourceValues(forKeys: [.volumeNameKey])
            .volumeName
        let name = resourceName ?? dmgURL.deletingPathExtension().lastPathComponent
        return String(name.prefix(Defaults.volumeNameLimit))
    }

    // MARK: - .DS_Store

    /// Reads and parses the volume's `.DS_Store`. A missing or malformed store
    /// yields `nil` — the import proceeds with default layout.
    private static func readDSStore(at mountPoint: URL) -> DSStoreReader.Contents? {
        guard let data = try? Data(
            contentsOf: mountPoint.appending(path: ".DS_Store")
        ) else { return nil }
        return try? DSStoreReader.read(data)
    }

    /// Maps window geometry and icon-view preferences onto the configuration,
    /// inverting the Finder conventions ``DSStoreWriter`` applied on write.
    private static func applyViewSettings(
        _ dsStore: DSStoreReader.Contents?,
        to configuration: inout DMGConfiguration
    ) {
        guard let dsStore else { return }

        if let bounds = dsStore.windowBounds {
            configuration.window.width = max(
                bounds.width.rounded(), Defaults.minimumWindowWidth
            )
            configuration.window.height = max(
                (bounds.height - DSStoreWriter.finderTitleBarHeight).rounded(),
                Defaults.minimumWindowHeight
            )
            configuration.windowPosition = WindowPosition(
                x: Int(bounds.origin.x),
                y: Int(bounds.origin.y)
            )
        }
        if let iconSize = dsStore.iconSize {
            configuration.iconSize = CGFloat(iconSize).clamped(to: Defaults.iconSizeRange)
        }
        if let textSize = dsStore.textSize {
            configuration.textSize = CGFloat(textSize).clamped(to: Defaults.textSizeRange)
        }
        if let gridSpacing = dsStore.gridSpacing {
            configuration.gridSpacing = CGFloat(gridSpacing).clamped(to: Defaults.gridSpacingRange)
            configuration.isGridSpacingAuto = false
        }
    }

    // MARK: - Background

    private struct ResolvedBackground {
        let data: Data
        let fileName: String
        /// The root-level directory containing the image (e.g. `.background`),
        /// excluded from item classification; `nil` when the image sits at the
        /// volume root.
        let rootDirectoryName: String?
    }

    /// Resolves the background image for an image-type background: alias
    /// record first, then the conventional-directory scan for stale or
    /// unparseable aliases. `pBBk` bookmarks are ignored — they embed
    /// build-machine volume paths that no longer exist.
    private static func resolveBackground(
        dsStore: DSStoreReader.Contents?,
        mountPoint: URL
    ) -> ResolvedBackground? {
        guard dsStore?.backgroundKind == .image else { return nil }

        var imageURL: URL?
        if let aliasData = dsStore?.backgroundImageAliasData,
           let relativePath = AliasRecordReader.volumeRelativePath(from: aliasData) {
            let candidate = mountPoint.appending(path: relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) {
                imageURL = candidate
            }
        }
        if imageURL == nil {
            imageURL = AliasRecordReader.firstImage(inBackgroundDirectoryOf: mountPoint)
        }
        guard let imageURL, let data = try? Data(contentsOf: imageURL) else { return nil }

        let relative = imageURL.path.dropFirst(mountPoint.path.count)
        let components = relative.split(separator: "/").map(String.init)
        return ResolvedBackground(
            data: data,
            fileName: imageURL.lastPathComponent,
            rootDirectoryName: components.count > 1 ? components.first : nil
        )
    }

    /// Applies the resolved background as a single image layer, or maps a
    /// solid-color background straight onto the model.
    private static func applyBackground(
        _ background: ResolvedBackground?,
        dsStore: DSStoreReader.Contents?,
        to configuration: inout DMGConfiguration,
        assets: inout [String: Data]
    ) {
        if let background {
            let layerID = UUID()
            let fileExtension = (background.fileName as NSString).pathExtension.lowercased()
            let imageName = "bg-\(layerID.uuidString).\(fileExtension.isEmpty ? "png" : fileExtension)"

            configuration.background.type = .image
            configuration.background.layers = [
                BackgroundLayer(
                    id: layerID,
                    imageName: imageName,
                    label: background.fileName,
                    position: CGPoint(
                        x: configuration.window.width / 2,
                        y: configuration.window.height / 2
                    )
                ),
            ]
            assets[imageName] = background.data
        } else if case let .color(red, green, blue) = dsStore?.backgroundKind {
            configuration.background.type = .color
            configuration.background.color = RGBColor(red: red, green: green, blue: blue)
        }
    }

    // MARK: - Item Classification

    /// Classifies the volume's root entries into canvas items, skipping
    /// housekeeping entries and the background image's directory. Items are
    /// returned in name order with placeholder positions.
    private static func classifyRootItems(
        at mountPoint: URL,
        excludingDirectory backgroundDirectory: String?
    ) throws -> [CanvasItem] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: mountPoint,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var items: [CanvasItem] = []
        for entry in entries {
            let name = entry.lastPathComponent
            if housekeepingNames.contains(name.lowercased()) { continue }
            if let backgroundDirectory, name == backgroundDirectory { continue }

            let values = try? entry.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isDirectoryKey]
            )
            if values?.isSymbolicLink == true {
                items.append(symlinkItem(at: entry, name: name))
            } else if values?.isDirectory == true, entry.pathExtension.lowercased() == "app" {
                items.append(CanvasItem(kind: .app, label: name, position: .zero))
            } else {
                items.append(CanvasItem(
                    kind: values?.isDirectory == true ? .folder : .file,
                    label: name,
                    position: .zero
                ))
            }
        }
        return items
    }

    private static func symlinkItem(at url: URL, name: String) -> CanvasItem {
        let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
        let normalized = destination.hasSuffix("/") && destination.count > 1
            ? String(destination.dropLast())
            : destination

        if normalized == "/Applications" {
            return CanvasItem(kind: .applicationsSymlink, label: name, position: .zero)
        }

        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory)
        return CanvasItem(
            kind: isDirectory.boolValue ? .folder : .file,
            label: name,
            sourcePath: normalized.isEmpty ? nil : normalized,
            position: .zero,
            linkType: .symlink
        )
    }

    // MARK: - Positions

    /// Assigns canvas positions from `Iloc` records, inverting Finder's icon
    /// view content inset. Items without a stored position are spread evenly
    /// along the window's vertical center.
    private static func assignPositions(
        to items: inout [CanvasItem],
        dsStore: DSStoreReader.Contents?,
        window: WindowConfiguration
    ) {
        var unplaced: [Int] = []
        for index in items.indices {
            if let raw = dsStore?.iconPositions[items[index].label] {
                items[index].position = CGPoint(
                    x: raw.x,
                    y: raw.y + DSStoreWriter.finderContentInset
                )
            } else {
                unplaced.append(index)
            }
        }
        guard !unplaced.isEmpty else { return }

        let centerY = round(window.height / 2)
        for (order, index) in unplaced.enumerated() {
            let x = round(window.width * CGFloat(order + 1) / CGFloat(unplaced.count + 1))
            items[index].position = CGPoint(x: x, y: centerY)
        }
    }

    // MARK: - App Icons

    /// Reads each app item's bundled `.icns` while the volume is still mounted
    /// so the canvas can show real icons for missing-source items.
    private static func harvestAppIcons(
        for items: [CanvasItem],
        mountPoint: URL
    ) -> [UUID: Data] {
        var icons: [UUID: Data] = [:]
        for item in items where item.kind == .app {
            let appPath = mountPoint.appending(path: item.label).path
            guard let iconURL = IconComposer.resolveAppIconURL(appPath: appPath),
                  let data = try? Data(contentsOf: iconURL)
            else { continue }
            icons[item.id] = data
        }
        return icons
    }
}

// MARK: - Clamping

private nonisolated extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
