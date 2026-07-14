import AppKit
@preconcurrency import Combine
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// ReferenceFileDocument requires ObservableObject. The @Observable macro provides
/// fine-grained view observation, while objectWillChange signals document dirtiness
/// for auto-save. Both conformances are intentional and required.
@Observable
final class RilmazafoneDocument: ReferenceFileDocument, ObservableObject, @unchecked Sendable {
    @ObservationIgnored let objectWillChange = ObservableObjectPublisher()

    // MARK: - Persisted State

    var configuration: DMGConfiguration

    // MARK: - Runtime State

    var backgroundImages: [UUID: NSImage] = [:]
    var volumeIconImage: NSImage?
    var appIconImage: NSImage?

    /// IDs of items whose copy-source is currently unreachable. Runtime state,
    /// never persisted; recomputed on open, add, remove, relink, and before builds.
    var missingSourceIDs: Set<UUID> = []

    /// The document's on-disk URL, fed in by the hosting view.
    ///
    /// `ReferenceFileDocument` exposes no URL in its read or write configurations,
    /// so `DocumentContentView` forwards `\.documentConfiguration`'s `fileURL` via
    /// ``documentFileURLDidChange(_:)`` — on open, after the first save of an
    /// untitled document, and after Save As or a move.
    @ObservationIgnored private(set) var fileURL: URL?

    // MARK: - File Wrappers

    @ObservationIgnored var assetsWrapper: FileWrapper?

    // MARK: - UTType

    nonisolated static let readableContentTypes: [UTType] = [.rilmazafoneDocument]

    // MARK: - Init

    init() {
        self.configuration = DMGConfiguration()
    }

    init(configuration: ReadConfiguration) throws {
        guard let directoryWrapper = configuration.file.fileWrappers else {
            throw CocoaError(.fileReadCorruptFile)
        }

        guard let manifestWrapper = directoryWrapper["document.json"],
              let manifestData = manifestWrapper.regularFileContents
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var decoded = try JSONDecoder().decode(
            DMGConfiguration.self,
            from: manifestData
        )
        decoded.expandAbbreviatedPaths()
        self.configuration = decoded
        self.assetsWrapper = directoryWrapper["Assets"]

        loadCachedImages()
    }

    // MARK: - Snapshots

    struct Snapshot {
        let configuration: DMGConfiguration
        let assetsWrapper: FileWrapper?
    }

    func snapshot(contentType _: UTType) throws -> Snapshot {
        var portable = configuration
        portable.abbreviatePaths()
        return Snapshot(
            configuration: portable,
            assetsWrapper: assetsWrapper
        )
    }

    func fileWrapper(
        snapshot: Snapshot,
        configuration _: WriteConfiguration
    ) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(snapshot.configuration)

        let directory = FileWrapper(directoryWithFileWrappers: [:])

        directory.addRegularFile(
            withContents: manifestData,
            preferredFilename: "document.json"
        )

        if let assets = snapshot.assetsWrapper {
            let assetsCopy = FileWrapper(
                directoryWithFileWrappers: assets.fileWrappers ?? [:]
            )
            assetsCopy.preferredFilename = "Assets"
            directory.addFileWrapper(assetsCopy)
        }

        return directory
    }

    // MARK: - Undo Registration

    func withUndo(
        _ undoManager: UndoManager?,
        _ actionName: String,
        _ handler: @escaping @Sendable (RilmazafoneDocument, UndoManager?) -> Void
    ) {
        MainActor.assumeIsolated {
            undoManager?.registerUndo(withTarget: self) { doc in
                handler(doc, undoManager)
            }
            undoManager?.setActionName(actionName)
        }
    }

    // MARK: - Undo-Aware Mutations

    func setVolumeName(_ newValue: String, undoManager: UndoManager?) {
        let oldValue = configuration.volumeName
        configuration.volumeName = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Volume Name") { doc, um in
            doc.setVolumeName(oldValue, undoManager: um)
        }
    }

    func setWindowWidth(_ newValue: CGFloat, undoManager: UndoManager?) {
        let oldValue = configuration.window.width
        configuration.window.width = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Window Width") { doc, um in
            doc.setWindowWidth(oldValue, undoManager: um)
        }
    }

    func setWindowHeight(_ newValue: CGFloat, undoManager: UndoManager?) {
        let oldValue = configuration.window.height
        configuration.window.height = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Window Height") { doc, um in
            doc.setWindowHeight(oldValue, undoManager: um)
        }
    }

    func setWindowSize(width: CGFloat, height: CGFloat, undoManager: UndoManager?) {
        let oldWidth = configuration.window.width
        let oldHeight = configuration.window.height
        configuration.window.width = width
        configuration.window.height = height
        objectWillChange.send()
        withUndo(undoManager, "Change Window Size") { doc, um in
            doc.setWindowSize(width: oldWidth, height: oldHeight, undoManager: um)
        }
    }

    func setIconSize(_ newValue: CGFloat, undoManager: UndoManager?) {
        let clamped = min(max(newValue, 16), 512)
        let oldValue = configuration.iconSize
        configuration.iconSize = clamped
        objectWillChange.send()
        withUndo(undoManager, "Change Icon Size") { doc, um in
            doc.setIconSize(oldValue, undoManager: um)
        }
    }

    func setTextSize(_ newValue: CGFloat, undoManager: UndoManager?) {
        let clamped = min(max(newValue, 10), 16)
        let oldValue = configuration.textSize
        configuration.textSize = clamped
        objectWillChange.send()
        withUndo(undoManager, "Change Text Size") { doc, um in
            doc.setTextSize(oldValue, undoManager: um)
        }
    }

    func setGridSpacing(_ newValue: CGFloat, undoManager: UndoManager?) {
        let clamped = min(max(newValue, 1), 100)
        let oldValue = configuration.gridSpacing
        configuration.gridSpacing = clamped
        objectWillChange.send()
        withUndo(undoManager, "Change Grid Spacing") { doc, um in
            doc.setGridSpacing(oldValue, undoManager: um)
        }
    }

    func setGridSpacingAuto(_ newValue: Bool, undoManager: UndoManager?) {
        let oldValue = configuration.isGridSpacingAuto
        configuration.isGridSpacingAuto = newValue
        objectWillChange.send()
        withUndo(undoManager, newValue ? "Auto Grid Spacing" : "Custom Grid Spacing") { doc, um in
            doc.setGridSpacingAuto(oldValue, undoManager: um)
        }
    }

    func setHideExtensions(_ newValue: Bool, undoManager: UndoManager?) {
        let oldValue = configuration.hideExtensions
        configuration.hideExtensions = newValue
        objectWillChange.send()
        withUndo(undoManager, newValue ? "Hide Extensions" : "Show Extensions") { doc, um in
            doc.setHideExtensions(oldValue, undoManager: um)
        }
    }

    func setBackgroundType(_ newValue: BackgroundType, undoManager: UndoManager?) {
        let oldValue = configuration.background.type
        configuration.background.type = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Background Type") { doc, um in
            doc.setBackgroundType(oldValue, undoManager: um)
        }
    }

    func setBackgroundColor(_ newValue: RGBColor, undoManager: UndoManager?) {
        let oldValue = configuration.background.color
        configuration.background.color = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Background Color") { doc, um in
            doc.setBackgroundColor(oldValue, undoManager: um)
        }
    }

    /// Checks if the item's app bundle is code signed, and if the signing
    /// identity exists in the user's keychain. Enables code signing with that
    /// identity if found, otherwise leaves it disabled.
    ///
    /// Reads the bundle's signature under security scope so it works for
    /// bookmark-backed sources in the sandboxed build.
    func configureCodeSigning(for item: CanvasItem, undoManager: UndoManager?) async {
        let authority = SourceAccess.withScope(item: item, documentURL: fileURL) { url in
            url.flatMap { DMGBuilder.signingAuthority(of: $0) }
        }
        guard let authority else { return }

        guard let identity = DMGBuilder.findMatchingKeychainIdentity(
            authority: authority
        ) else { return }

        setCodeSignEnabled(true, undoManager: undoManager)
        setCodeSignIdentity(identity, undoManager: undoManager)
    }

    func setCodeSignEnabled(_ newValue: Bool, undoManager: UndoManager?) {
        let oldValue = configuration.codeSign.enabled
        configuration.codeSign.enabled = newValue
        objectWillChange.send()
        withUndo(undoManager, newValue ? "Enable Code Signing" : "Disable Code Signing") { doc, um in
            doc.setCodeSignEnabled(oldValue, undoManager: um)
        }
    }

    func setVolumeIconType(_ newValue: VolumeIconType, undoManager: UndoManager?) {
        let oldValue = configuration.volumeIcon.type
        configuration.volumeIcon.type = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Volume Icon") { doc, um in
            doc.setVolumeIconType(oldValue, undoManager: um)
        }
    }

    // MARK: - Gradient

    func setGradientConfiguration(to newValue: GradientConfiguration?, undoManager: UndoManager?) {
        let oldValue = configuration.background.gradient
        configuration.background.gradient = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Gradient") { doc, um in
            doc.setGradientConfiguration(to: oldValue, undoManager: um)
        }
    }

    // MARK: - Background Import Convenience

    func importBackgroundImage(from url: URL, undoManager: UndoManager?) throws {
        try addBackgroundLayer(from: url, undoManager: undoManager)
    }

    // MARK: - Volume Icon Import

    func importVolumeIcon(from url: URL, undoManager: UndoManager?) throws {
        let data = try Data(contentsOf: url)
        let filename = "volume-icon.\(url.pathExtension)"

        ensureAssetsWrapper()
        replaceAsset(named: filename, with: data)

        let oldConfig = configuration.volumeIcon
        let oldImage = volumeIconImage
        configuration.volumeIcon = VolumeIconConfiguration(type: .custom, sourceIconName: filename)
        volumeIconImage = NSImage(data: data)
        objectWillChange.send()

        withUndo(undoManager, "Set Custom Volume Icon") { doc, _ in
            doc.configuration.volumeIcon = oldConfig
            doc.volumeIconImage = oldImage
        }
    }

    func setDMGFormat(_ newValue: DMGImageFormat, undoManager: UndoManager?) {
        let oldValue = configuration.dmgFormat
        configuration.dmgFormat = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change DMG Format") { doc, um in
            doc.setDMGFormat(oldValue, undoManager: um)
        }
    }

    func setFilesystem(_ newValue: DMGFilesystem, undoManager: UndoManager?) {
        let oldValue = configuration.filesystem
        configuration.filesystem = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Filesystem") { doc, um in
            doc.setFilesystem(oldValue, undoManager: um)
        }
    }

    func setCodeSignIdentity(_ identity: String?, undoManager: UndoManager?) {
        let oldValue = configuration.codeSign.identity
        configuration.codeSign.identity = identity
        objectWillChange.send()
        withUndo(undoManager, "Change Signing Identity") { doc, um in
            doc.setCodeSignIdentity(oldValue, undoManager: um)
        }
    }

    // MARK: - Asset Extraction

    func extractAssetsToTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "rilmazafone-assets-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        guard let assets = assetsWrapper?.fileWrappers else {
            return tempDir
        }

        for (filename, wrapper) in assets {
            guard let data = wrapper.regularFileContents else { continue }
            let fileURL = tempDir.appending(path: filename)
            try data.write(to: fileURL)
        }

        return tempDir
    }

    // MARK: - Source Bookmarks & Availability

    /// Records the document's on-disk URL and reconciles item sources against it.
    ///
    /// Called by the hosting view whenever `\.documentConfiguration`'s `fileURL`
    /// changes (including initially). In the App Store build this is where item
    /// bookmarks are resolved: paths are refreshed from resolved bookmarks (the
    /// bookmark wins under sandbox), stale bookmarks are re-created, and bookmarks
    /// created app-scoped while the document was untitled are upgraded to document
    /// scope now that a document URL exists. Any bookmark change marks the document
    /// dirty so the upgrade persists on the next (auto)save.
    func documentFileURLDidChange(_ url: URL?) {
        fileURL = url
        #if APPSTORE
            reconcileSourceBookmarks()
        #endif
        refreshSourceStates()
    }

    /// Recomputes ``missingSourceIDs`` from the items' current on-disk state.
    func refreshSourceStates() {
        let missing = Set(
            configuration.items
                .filter { !SourceAccess.isSourceAvailable(item: $0, documentURL: fileURL) }
                .map(\.id)
        )
        if missing != missingSourceIDs {
            missingSourceIDs = missing
        }
    }

    #if APPSTORE
        private func reconcileSourceBookmarks() {
            var didChange = false
            for index in configuration.items.indices {
                let item = configuration.items[index]
                guard item.requiresSource,
                      let bookmark = item.sourceBookmark,
                      let reconciliation = SourceAccess.reconcile(
                          bookmark: bookmark, documentURL: fileURL
                      )
                else { continue }

                if let refreshed = reconciliation.refreshedBookmark {
                    configuration.items[index].sourceBookmark = refreshed
                    didChange = true
                }
                if configuration.items[index].sourcePath != reconciliation.url.path {
                    configuration.items[index].sourcePath = reconciliation.url.path
                    didChange = true
                }
            }
            if didChange {
                objectWillChange.send()
            }
        }
    #endif

    // MARK: - Queries

    var hasApp: Bool {
        configuration.items.contains { $0.kind == .app }
    }

    /// Check if a UUID belongs to a background layer
    func backgroundLayer(for id: UUID) -> BackgroundLayer? {
        configuration.background.layers.first { $0.id == id }
    }

    /// Check if a UUID belongs to a text layer
    func textLayer(for id: UUID) -> TextLayerConfiguration? {
        configuration.textLayers.first { $0.id == id }
    }

    /// Check if a UUID belongs to an SF symbol layer
    func sfSymbolLayer(for id: UUID) -> SFSymbolLayerConfiguration? {
        configuration.sfSymbolLayers.first { $0.id == id }
    }

    // MARK: - Private

    private func loadCachedImages() {
        guard let assets = assetsWrapper?.fileWrappers else { return }

        backgroundImages.removeAll()
        for layer in configuration.background.layers {
            if let wrapper = assets[layer.imageName],
               let data = wrapper.regularFileContents {
                backgroundImages[layer.id] = NSImage(data: data)
            }
        }

        if let iconName = configuration.volumeIcon.sourceIconName,
           let iconWrapper = assets[iconName],
           let iconData = iconWrapper.regularFileContents {
            volumeIconImage = NSImage(data: iconData)
        }
    }

    func ensureAssetsWrapper() {
        if assetsWrapper == nil {
            assetsWrapper = FileWrapper(directoryWithFileWrappers: [:])
            assetsWrapper?.preferredFilename = "Assets"
        }
    }

    func replaceAsset(named filename: String, with data: Data) {
        if let existing = assetsWrapper?.fileWrappers?[filename] {
            assetsWrapper?.removeFileWrapper(existing)
        }
        let wrapper = FileWrapper(regularFileWithContents: data)
        wrapper.preferredFilename = filename
        assetsWrapper?.addFileWrapper(wrapper)
    }
}
