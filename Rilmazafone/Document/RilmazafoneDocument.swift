import AppKit
@preconcurrency import Combine
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// ReferenceFileDocument requires ObservableObject. The @Observable macro provides
/// fine-grained view observation, while objectWillChange signals document dirtiness
/// for auto-save. Both conformances are intentional and required.
///
/// The class is MainActor-isolated (the project default), which also makes it
/// `Sendable` — the compiler now enforces the main-thread access that the undo
/// machinery's `assumeIsolated` previously only asserted at runtime. The two
/// deliberately `nonisolated` members are the ones AppKit/SwiftUI invoke off
/// the main thread: `init()` (document shell instantiation) and
/// `fileWrapper(snapshot:configuration:)` (background write of a Sendable
/// snapshot).
@Observable
final class RilmazafoneDocument: ReferenceFileDocument, ObservableObject {
    @ObservationIgnored let objectWillChange = ObservableObjectPublisher()

    // MARK: - Persisted State (Observation Slices)

    // The document model is stored as four hot slices plus a remainder so a
    // mutation invalidates only the views that read its slice. `configuration`
    // below reassembles the full model for serialization, builds, and other
    // cold paths.

    /// The canvas items slice of the document model.
    var items: [CanvasItem] {
        didSet { itemsGeneration &+= 1 }
    }

    /// The background slice of the document model.
    var background: BackgroundConfiguration {
        didSet { backgroundGeneration &+= 1 }
    }

    /// The text layers slice of the document model.
    var textLayers: [TextLayerConfiguration] {
        didSet { textLayersGeneration &+= 1 }
    }

    /// The SF Symbol layers slice of the document model.
    var sfSymbolLayers: [SFSymbolLayerConfiguration] {
        didSet { sfSymbolLayersGeneration &+= 1 }
    }

    /// Every configuration field outside the four hot slices (volume name,
    /// window, sizes, code signing, formats, ...).
    ///
    /// Invariant: the slice fields inside (`items`, `background`, `textLayers`,
    /// `sfSymbolLayers`) always hold their empty/default values. ``split(_:)``
    /// is the only place that constructs this value, which keeps the design
    /// drift-safe: any future `DMGConfiguration` field automatically lives here.
    private var rest: DMGConfiguration {
        didSet { restGeneration &+= 1 }
    }

    /// The full document model, reassembled from the observation slices.
    ///
    /// Reading registers an observation dependency on all five stored slices,
    /// so view hot paths should read the slice properties (or the `rest`-backed
    /// accessors) instead; cold paths (snapshot, build, template save, import)
    /// read this freely. Writing replaces every slice — mutators must write
    /// their slice directly rather than going through this setter.
    var configuration: DMGConfiguration {
        get {
            var full = rest
            full.items = items
            full.background = background
            full.textLayers = textLayers
            full.sfSymbolLayers = sfSymbolLayers
            return full
        }
        set {
            let slices = Self.split(newValue)
            items = slices.items
            background = slices.background
            textLayers = slices.textLayers
            sfSymbolLayers = slices.sfSymbolLayers
            rest = slices.rest
        }
    }

    // MARK: - Slice Generations

    // Monotonic version counters bumped whenever their slice changes. They are
    // tracked (deliberately not @ObservationIgnored) so reading one registers
    // an observation dependency exactly as fine-grained as the slice it
    // versions — task fingerprints read the counters instead of deep-hashing
    // the model, staying O(1) in document size while still invalidating.

    private(set) var itemsGeneration: UInt64 = 0
    private(set) var backgroundGeneration: UInt64 = 0
    private(set) var textLayersGeneration: UInt64 = 0
    private(set) var sfSymbolLayersGeneration: UInt64 = 0
    private(set) var restGeneration: UInt64 = 0
    private(set) var imagesGeneration: UInt64 = 0

    // MARK: - Rest-Backed Accessors

    // Read-only views into `rest` for view hot paths: reading one registers a
    // dependency on `rest` alone instead of the whole reassembled
    // `configuration`. Mutations go through the undo-aware setters below.

    var volumeName: String { rest.volumeName }
    var window: WindowConfiguration { rest.window }
    var iconSize: CGFloat { rest.iconSize }
    var textSize: CGFloat { rest.textSize }
    var gridSpacing: CGFloat { rest.gridSpacing }
    var isGridSpacingAuto: Bool { rest.isGridSpacingAuto }
    var hideExtensions: Bool { rest.hideExtensions }
    var volumeIcon: VolumeIconConfiguration { rest.volumeIcon }
    var dmgFormat: DMGImageFormat { rest.dmgFormat }
    var filesystem: DMGFilesystem { rest.filesystem }

    /// The code-signing slice of `rest`. Settable so mutators in other files
    /// (placeholder filling) can write it without access to the private `rest`.
    var codeSign: CodeSignConfiguration {
        get { rest.codeSign }
        set { rest.codeSign = newValue }
    }

    // MARK: - Slice Splitting

    private struct ConfigurationSlices {
        var items: [CanvasItem]
        var background: BackgroundConfiguration
        var textLayers: [TextLayerConfiguration]
        var sfSymbolLayers: [SFSymbolLayerConfiguration]
        var rest: DMGConfiguration
    }

    /// Splits a full configuration into the four hot slices plus the pruned
    /// remainder, upholding the `rest` invariant. Used by the `configuration`
    /// setter and the inits (which assign stored properties directly).
    private nonisolated static func split(
        _ full: DMGConfiguration
    ) -> ConfigurationSlices {
        var rest = full
        rest.items = []
        rest.background = BackgroundConfiguration()
        rest.textLayers = []
        rest.sfSymbolLayers = []
        return ConfigurationSlices(
            items: full.items,
            background: full.background,
            textLayers: full.textLayers,
            sfSymbolLayers: full.sfSymbolLayers,
            rest: rest
        )
    }

    // MARK: - Runtime State

    var backgroundImages: [UUID: NSImage] = [:] {
        didSet { imagesGeneration &+= 1 }
    }
    var volumeIconImage: NSImage?
    var appIconImage: NSImage?

    /// IDs of items whose copy-source is currently unreachable. Runtime state,
    /// never persisted; recomputed on open, add, remove, relink, and before builds.
    var missingSourceIDs: Set<UUID> = []

    /// App icons harvested during DMG import, keyed by item ID. Runtime state,
    /// never persisted: lets the canvas show the real icon for items whose
    /// in-DMG source is unreachable while the missing-source badge drives
    /// relinking.
    var importedItemIcons: [UUID: NSImage] = [:]

    /// Label legibility warnings from the debounced background contrast analysis.
    /// Runtime state, never persisted; written by `DocumentContentView`'s analysis
    /// task and read by the canvas badges, sidebar rows, toolbar chip, and build
    /// sheet notice.
    var legibilityWarnings: Set<LegibilityWarning> = []

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

    /// Nonisolated because AppKit instantiates the document shell on a
    /// background queue when opening an existing file.
    nonisolated init() {
        self.items = []
        self.background = BackgroundConfiguration()
        self.textLayers = []
        self.sfSymbolLayers = []
        self.rest = DMGConfiguration()
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
        let slices = Self.split(decoded)
        self.items = slices.items
        self.background = slices.background
        self.textLayers = slices.textLayers
        self.sfSymbolLayers = slices.sfSymbolLayers
        self.rest = slices.rest
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
        _ handler: @escaping @MainActor @Sendable (RilmazafoneDocument, UndoManager?) -> Void
    ) {
        undoManager?.registerUndo(withTarget: self) { doc in
            // NSUndoManager fires document undo actions on the main thread;
            // this is the one runtime assertion of that contract, so the
            // MainActor-typed handler can run statically checked.
            MainActor.assumeIsolated {
                handler(doc, undoManager)
            }
        }
        undoManager?.setActionName(actionName)
    }

    // MARK: - Undo-Aware Mutations

    func setVolumeName(_ newValue: String, undoManager: UndoManager?) {
        let oldValue = rest.volumeName
        rest.volumeName = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Volume Name") { doc, um in
            doc.setVolumeName(oldValue, undoManager: um)
        }
    }

    func setWindowWidth(_ newValue: CGFloat, undoManager: UndoManager?) {
        let oldValue = rest.window.width
        rest.window.width = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Window Width") { doc, um in
            doc.setWindowWidth(oldValue, undoManager: um)
        }
    }

    func setWindowHeight(_ newValue: CGFloat, undoManager: UndoManager?) {
        let oldValue = rest.window.height
        rest.window.height = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Window Height") { doc, um in
            doc.setWindowHeight(oldValue, undoManager: um)
        }
    }

    func setWindowSize(width: CGFloat, height: CGFloat, undoManager: UndoManager?) {
        let oldWidth = rest.window.width
        let oldHeight = rest.window.height
        rest.window.width = width
        rest.window.height = height
        objectWillChange.send()
        withUndo(undoManager, "Change Window Size") { doc, um in
            doc.setWindowSize(width: oldWidth, height: oldHeight, undoManager: um)
        }
    }

    func setIconSize(_ newValue: CGFloat, undoManager: UndoManager?) {
        let clamped = min(max(newValue, 16), 512)
        let oldValue = rest.iconSize
        rest.iconSize = clamped
        objectWillChange.send()
        withUndo(undoManager, "Change Icon Size") { doc, um in
            doc.setIconSize(oldValue, undoManager: um)
        }
    }

    func setTextSize(_ newValue: CGFloat, undoManager: UndoManager?) {
        let clamped = min(max(newValue, 10), 16)
        let oldValue = rest.textSize
        rest.textSize = clamped
        objectWillChange.send()
        withUndo(undoManager, "Change Text Size") { doc, um in
            doc.setTextSize(oldValue, undoManager: um)
        }
    }

    func setGridSpacing(_ newValue: CGFloat, undoManager: UndoManager?) {
        let clamped = min(max(newValue, 1), 100)
        let oldValue = rest.gridSpacing
        rest.gridSpacing = clamped
        objectWillChange.send()
        withUndo(undoManager, "Change Grid Spacing") { doc, um in
            doc.setGridSpacing(oldValue, undoManager: um)
        }
    }

    func setGridSpacingAuto(_ newValue: Bool, undoManager: UndoManager?) {
        let oldValue = rest.isGridSpacingAuto
        rest.isGridSpacingAuto = newValue
        objectWillChange.send()
        withUndo(undoManager, newValue ? "Auto Grid Spacing" : "Custom Grid Spacing") { doc, um in
            doc.setGridSpacingAuto(oldValue, undoManager: um)
        }
    }

    func setHideExtensions(_ newValue: Bool, undoManager: UndoManager?) {
        let oldValue = rest.hideExtensions
        rest.hideExtensions = newValue
        objectWillChange.send()
        withUndo(undoManager, newValue ? "Hide Extensions" : "Show Extensions") { doc, um in
            doc.setHideExtensions(oldValue, undoManager: um)
        }
    }

    func setBackgroundType(_ newValue: BackgroundType, undoManager: UndoManager?) {
        let oldValue = background.type
        background.type = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Background Type") { doc, um in
            doc.setBackgroundType(oldValue, undoManager: um)
        }
    }

    func setBackgroundColor(_ newValue: RGBColor, undoManager: UndoManager?) {
        let oldValue = background.color
        background.color = newValue
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
        let oldValue = rest.codeSign.enabled
        rest.codeSign.enabled = newValue
        objectWillChange.send()
        withUndo(undoManager, newValue ? "Enable Code Signing" : "Disable Code Signing") { doc, um in
            doc.setCodeSignEnabled(oldValue, undoManager: um)
        }
    }

    func setVolumeIconType(_ newValue: VolumeIconType, undoManager: UndoManager?) {
        let oldValue = rest.volumeIcon.type
        rest.volumeIcon.type = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Volume Icon") { doc, um in
            doc.setVolumeIconType(oldValue, undoManager: um)
        }
    }

    // MARK: - Gradient

    func setGradientConfiguration(to newValue: GradientConfiguration?, undoManager: UndoManager?) {
        let oldValue = background.gradient
        background.gradient = newValue
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

        let oldConfig = rest.volumeIcon
        let oldImage = volumeIconImage
        rest.volumeIcon = VolumeIconConfiguration(type: .custom, sourceIconName: filename)
        volumeIconImage = NSImage(data: data)
        objectWillChange.send()

        withUndo(undoManager, "Set Custom Volume Icon") { doc, _ in
            doc.rest.volumeIcon = oldConfig
            doc.volumeIconImage = oldImage
        }
    }

    func setDMGFormat(_ newValue: DMGImageFormat, undoManager: UndoManager?) {
        let oldValue = rest.dmgFormat
        rest.dmgFormat = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change DMG Format") { doc, um in
            doc.setDMGFormat(oldValue, undoManager: um)
        }
    }

    func setFilesystem(_ newValue: DMGFilesystem, undoManager: UndoManager?) {
        let oldValue = rest.filesystem
        rest.filesystem = newValue
        objectWillChange.send()
        withUndo(undoManager, "Change Filesystem") { doc, um in
            doc.setFilesystem(oldValue, undoManager: um)
        }
    }

    func setCodeSignIdentity(_ identity: String?, undoManager: UndoManager?) {
        let oldValue = rest.codeSign.identity
        rest.codeSign.identity = identity
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
            items
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
            for index in items.indices {
                let item = items[index]
                guard item.requiresSource,
                      let bookmark = item.sourceBookmark,
                      let reconciliation = SourceAccess.reconcile(
                          bookmark: bookmark, documentURL: fileURL
                      )
                else { continue }

                if let refreshed = reconciliation.refreshedBookmark {
                    items[index].sourceBookmark = refreshed
                    didChange = true
                }
                if items[index].sourcePath != reconciliation.url.path {
                    items[index].sourcePath = reconciliation.url.path
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
        items.contains { $0.kind == .app }
    }

    /// Check if a UUID belongs to a background layer
    func backgroundLayer(for id: UUID) -> BackgroundLayer? {
        background.layers.first { $0.id == id }
    }

    /// Check if a UUID belongs to a text layer
    func textLayer(for id: UUID) -> TextLayerConfiguration? {
        textLayers.first { $0.id == id }
    }

    /// Check if a UUID belongs to an SF symbol layer
    func sfSymbolLayer(for id: UUID) -> SFSymbolLayerConfiguration? {
        sfSymbolLayers.first { $0.id == id }
    }

    // MARK: - Legibility

    /// The appearance modes an item's label is flagged for, in display order.
    func legibilityModes(for id: UUID) -> [LabelAppearanceMode] {
        LabelAppearanceMode.allCases.filter { mode in
            legibilityWarnings.contains(LegibilityWarning(itemID: id, mode: mode))
        }
    }

    /// One-line aggregate of the current legibility warnings with correct
    /// pluralization, or `nil` when there are none. Shared by the toolbar chip
    /// and the build sheet notice.
    var legibilitySummary: String? {
        let flaggedCount = Set(legibilityWarnings.map(\.itemID)).count
        guard flaggedCount > 0 else { return nil }

        let noun = flaggedCount == 1 ? "label" : "labels"
        let modes = Set(legibilityWarnings.map(\.mode))
        let suffix: String = if modes == [.dark] {
            "in Dark Mode"
        } else if modes == [.light] {
            "in Light Mode"
        } else {
            "in Light and Dark Mode"
        }
        return "\(flaggedCount) \(noun) may be unreadable \(suffix)"
    }

    // MARK: - Private

    private func loadCachedImages() {
        guard let assets = assetsWrapper?.fileWrappers else { return }

        backgroundImages.removeAll()
        for layer in background.layers {
            if let wrapper = assets[layer.imageName],
               let data = wrapper.regularFileContents {
                backgroundImages[layer.id] = NSImage(data: data)
            }
        }

        if let iconName = rest.volumeIcon.sourceIconName,
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
