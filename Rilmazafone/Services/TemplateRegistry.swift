import AppKit
import Observation

// MARK: - Template Entry

/// A single `.dmgtemplate` package known to the registry.
nonisolated struct TemplateEntry: Identifiable, Hashable, Sendable {
    /// Where an item's filename label sits, in top-down content-space points —
    /// the gallery draws a redacted material pill there in place of the label
    /// text, which would be illegible at tile scale.
    struct LabelPill: Hashable, Sendable {
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    /// Location of the `.dmgtemplate` directory package.
    let url: URL

    /// Display name, derived from the package's file name.
    let name: String

    /// Whether the template ships inside the app bundle (read-only) as opposed
    /// to living in the user's template library.
    let isBuiltIn: Bool

    /// The Finder window size the template's configuration declares.
    let windowSize: CGSize

    /// One pill per canvas item, in item order.
    let labelPills: [LabelPill]

    var id: URL { url }
}

// MARK: - Template Registry

/// Single source of truth for the template chooser, the File menu, and the
/// Dock menu: the Blank pseudo-entry plus bundled and user `.dmgtemplate`
/// packages, with cached thumbnails rendered by ``CompositeRenderer``.
///
/// Entries are loaded cheaply (each template's `document.json` only); full
/// thumbnails are rendered off the main thread and cached keyed on the
/// template's modification date. A `DispatchSource` watcher on the user
/// library refreshes the entry lists when templates are added or removed, so
/// every menu stays current without a relaunch.
@MainActor
@Observable
final class TemplateRegistry {
    static let shared = TemplateRegistry()

    // MARK: Entries

    /// Templates shipped in the app bundle, sorted by name. Empty when the
    /// bundle carries no `Templates` directory.
    private(set) var bundled: [TemplateEntry] = []

    /// Templates in the user's library, sorted by name.
    private(set) var user: [TemplateEntry] = []

    /// The window size a Blank document starts with (the model default).
    nonisolated static var blankWindowSize: CGSize {
        let window = WindowConfiguration()
        return CGSize(width: window.width, height: window.height)
    }

    // MARK: Locations

    /// `Templates` directory inside the app bundle's resources.
    nonisolated static var defaultBundledDirectory: URL? {
        Bundle.main.resourceURL?.appending(path: "Templates", directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/Rilmazafone/Templates` (container-relative
    /// in the sandboxed build).
    nonisolated static var defaultUserDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Rilmazafone/Templates", directoryHint: .isDirectory)
    }

    private let bundledDirectory: URL?
    let userDirectory: URL
    private var watcher: DirectoryWatcher?

    // MARK: Thumbnail Cache

    private struct CachedThumbnail {
        let modificationDate: Date?
        let image: NSImage
    }

    private var thumbnailCache: [URL: CachedThumbnail] = [:]
    private var thumbnailTasks: [URL: Task<NSImage?, Never>] = [:]

    // MARK: Init

    init(
        bundledDirectory: URL? = TemplateRegistry.defaultBundledDirectory,
        userDirectory: URL = TemplateRegistry.defaultUserDirectory,
        watchesUserDirectory: Bool = true,
        prewarmsThumbnails: Bool = true
    ) {
        self.bundledDirectory = bundledDirectory
        self.userDirectory = userDirectory

        try? FileManager.default.createDirectory(
            at: userDirectory, withIntermediateDirectories: true
        )

        refresh()

        if watchesUserDirectory {
            watcher = DirectoryWatcher(url: userDirectory) { [weak self] in
                DispatchQueue.main.async {
                    self?.refresh()
                }
            }
        }
        if prewarmsThumbnails {
            prewarmThumbnails()
        }
    }

    // MARK: Refresh

    /// Rescans both template directories. Called automatically when the user
    /// library changes on disk; safe to call explicitly after mutations.
    func refresh() {
        let scannedBundled = Self.scan(directory: bundledDirectory, isBuiltIn: true)
        let scannedUser = Self.scan(directory: userDirectory, isBuiltIn: false)
        if scannedBundled != bundled { bundled = scannedBundled }
        if scannedUser != user { user = scannedUser }
    }

    private nonisolated static func scan(directory: URL?, isBuiltIn: Bool) -> [TemplateEntry] {
        guard let directory,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              )
        else { return [] }

        return contents
            .filter { $0.pathExtension == "dmgtemplate" }
            .compactMap { url -> TemplateEntry? in
                guard let configuration = try? TemplateInstantiator.configuration(ofTemplateAt: url)
                else { return nil }
                return TemplateEntry(
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    isBuiltIn: isBuiltIn,
                    windowSize: CGSize(
                        width: configuration.window.width,
                        height: configuration.window.height
                    ),
                    labelPills: configuration.items.map { item in
                        TemplateThumbnailRenderer.labelPill(
                            for: item,
                            iconSize: configuration.iconSize,
                            textSize: configuration.textSize
                        )
                    }
                )
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    // MARK: Thumbnails

    /// Returns the template's thumbnail: the full ``CompositeRenderer``
    /// composite with item tiles drawn on top (real icons where resolvable,
    /// the dashed placeholder tile otherwise). Rendered off the main thread
    /// and cached keyed on the template's modification date.
    func thumbnail(for entry: TemplateEntry) async -> NSImage? {
        let modificationDate = Self.modificationDate(ofTemplateAt: entry.url)
        if let cached = thumbnailCache[entry.url],
           cached.modificationDate == modificationDate {
            return cached.image
        }
        if let inFlight = thumbnailTasks[entry.url] {
            return await inFlight.value
        }

        let task = Task(name: "Render template thumbnail \(entry.name)") { [weak self] in
            await self?.renderThumbnail(for: entry, modificationDate: modificationDate)
        }
        thumbnailTasks[entry.url] = task
        let image = await task.value
        thumbnailTasks[entry.url] = nil
        return image
    }

    /// Kicks off thumbnail rendering for every known entry so the chooser can
    /// open with cache hits. Rendering itself happens off the main thread.
    func prewarmThumbnails() {
        let entries = bundled + user
        Task(name: "Prewarm template thumbnails") { [weak self] in
            for entry in entries {
                guard let self else { return }
                _ = await self.thumbnail(for: entry)
            }
        }
    }

    private func renderThumbnail(
        for entry: TemplateEntry,
        modificationDate: Date?
    ) async -> NSImage? {
        guard let configuration = try? TemplateInstantiator.configuration(ofTemplateAt: entry.url)
        else { return nil }

        let itemIcons = resolveItemIcons(for: configuration)
        guard let cgImage = await TemplateThumbnailRenderer.render(
            configuration: configuration,
            assetsDirectory: entry.url.appending(path: "Assets"),
            itemIcons: itemIcons
        ) else { return nil }

        let image = NSImage(
            cgImage: cgImage,
            size: CGSize(width: configuration.window.width, height: configuration.window.height)
        )
        thumbnailCache[entry.url] = CachedThumbnail(
            modificationDate: modificationDate, image: image
        )
        return image
    }

    /// Resolves item icons on the main actor (IconServices and security scope
    /// are involved) as `CGImage`s the off-main renderer can consume.
    private func resolveItemIcons(for configuration: DMGConfiguration) -> [UUID: CGImage] {
        var icons: [UUID: CGImage] = [:]
        for item in configuration.items {
            guard let icon = CanvasItem.resolveIcon(for: item, documentURL: nil) else { continue }
            var proposedRect = CGRect(
                origin: .zero,
                size: CGSize(width: configuration.iconSize * 2, height: configuration.iconSize * 2)
            )
            if let cgIcon = icon.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) {
                icons[item.id] = cgIcon
            }
        }
        return icons
    }

    private nonisolated static func modificationDate(ofTemplateAt url: URL) -> Date? {
        try? url.appending(path: "document.json")
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    // MARK: - User Template Management

    /// Writes a new template into the user library and returns its entry.
    /// The name is sanitized for the filesystem and uniqued if a template
    /// with the same name already exists.
    @discardableResult
    func saveUserTemplate(
        named name: String,
        configuration: DMGConfiguration,
        assets: [String: Data] = [:]
    ) throws -> TemplateEntry {
        var portable = configuration
        portable.abbreviatePaths()

        let url = availableTemplateURL(for: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(portable).write(to: url.appending(path: "document.json"))

        if !assets.isEmpty {
            let assetsDirectory = url.appending(path: "Assets", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: assetsDirectory, withIntermediateDirectories: true
            )
            for (filename, data) in assets {
                try data.write(to: assetsDirectory.appending(path: filename))
            }
        }

        refresh()
        guard let entry = userEntry(at: url) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return entry
    }

    /// Renames a user template's package on disk and returns the new entry.
    @discardableResult
    func renameUserTemplate(_ entry: TemplateEntry, to newName: String) throws -> TemplateEntry {
        let destination = availableTemplateURL(for: newName)
        try FileManager.default.moveItem(at: entry.url, to: destination)
        refresh()
        guard let renamed = userEntry(at: destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return renamed
    }

    /// Looks up a user entry by location, tolerating the trailing-slash and
    /// `/private` variations between constructed and enumerated file URLs.
    private func userEntry(at url: URL) -> TemplateEntry? {
        let path = url.standardizedFileURL.path
        return user.first { $0.url.standardizedFileURL.path == path }
    }

    /// Moves a user template to the Trash (recoverable, never a hard delete).
    func deleteUserTemplate(_ entry: TemplateEntry) throws {
        try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
        thumbnailCache[entry.url] = nil
        refresh()
    }

    /// Reveals the template's package in Finder.
    func revealInFinder(_ entry: TemplateEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    /// The first free `<name>.dmgtemplate` URL in the user library, appending
    /// a counter when the plain name is taken.
    private func availableTemplateURL(for name: String) -> URL {
        let base = Self.sanitizedTemplateName(name)
        var candidate = userDirectory.appending(path: "\(base).dmgtemplate")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = userDirectory.appending(path: "\(base) \(counter).dmgtemplate")
            counter += 1
        }
        return candidate
    }

    /// Replaces filesystem-hostile characters and trims whitespace; falls back
    /// to "Template" for an effectively empty name.
    nonisolated static func sanitizedTemplateName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Template" : cleaned
    }
}

// MARK: - Directory Watcher

/// Watches a directory for content changes via a `DispatchSource` on an
/// `O_EVTONLY` file descriptor. The handler fires on a utility queue; the
/// caller is responsible for hopping to its own isolation.
private nonisolated final class DirectoryWatcher {
    private let source: any DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        let fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler {
            close(fileDescriptor)
        }
        source.resume()
        self.source = source
    }

    deinit {
        source.cancel()
    }
}
