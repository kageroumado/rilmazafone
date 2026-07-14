import AppleArchive
import Foundation
import System

/// Embedded item payloads: small files and folders stored inside a document or
/// template package's `Assets` directory so a design is portable across Macs.
///
/// A ``CanvasItem`` with a non-nil `assetName` sources its content from the
/// package instead of an external path — no source path, no security-scoped
/// bookmark, nothing to relink. Files are stored verbatim; folders are stored
/// as LZFSE-compressed Apple Archives (`.aar`) so the `[String: Data]` asset
/// plumbing shared by documents, templates, and DMG import carries both
/// shapes unchanged. ``materialize(items:assetsDirectory:stagingDirectory:)``
/// turns payloads back into ordinary filesystem sources at build time.
nonisolated enum EmbeddedAssets {
    enum EmbedError: Error, LocalizedError {
        /// A folder payload could not be archived or extracted.
        case archiveFailed(String)
        /// An item references a payload absent from the package's assets.
        case missingPayload(String)

        var errorDescription: String? {
            switch self {
            case let .archiveFailed(detail):
                "Could not process an embedded folder: \(detail)"
            case let .missingPayload(label):
                "The embedded content for \u{201C}\(label)\u{201D} is missing from the document."
            }
        }
    }

    /// Per-item payload cap (16 MB). Covers readmes, licenses, and pictures;
    /// anything larger is content that should ship by reference, not ride
    /// inside every copy of a template.
    static let sizeCap = 16 * 1_024 * 1_024

    /// Archive field key set from Apple's file-tree compression sample —
    /// enough to round-trip permissions, timestamps, and symlinks.
    private static let archiveFields = "TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM"

    // MARK: - Naming

    /// Unique asset filename for an item payload. Keeps the (sanitized) label
    /// so file payloads retain their real extension for icon/type resolution;
    /// folder payloads carry a `.aar` suffix marking the archive container.
    static func assetName(itemID: UUID, label: String, kind: CanvasItemKind) -> String {
        let sanitized = label
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let name = "item-\(itemID.uuidString.prefix(8))-\(sanitized)"
        return kind == .folder ? name + ".aar" : name
    }

    // MARK: - Embedding

    /// Reads the payload for a source at `url`, or `nil` when the source
    /// exceeds ``sizeCap``. Files are read verbatim; folders are archived.
    /// Only `.file` and `.folder` kinds embed — apps are placeholder slots by
    /// design and never carry payloads.
    static func payload(for url: URL, kind: CanvasItemKind) throws -> Data? {
        switch kind {
        case .file:
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= sizeCap
            else { return nil }
            return try Data(contentsOf: url)
        case .folder:
            guard directoryFitsCap(url) else { return nil }
            return try archive(directory: url)
        case .app, .applicationsSymlink:
            return nil
        }
    }

    /// Whether the directory's total logical size is within ``sizeCap``,
    /// bailing out of the walk as soon as the cap is exceeded.
    private static func directoryFitsCap(_ url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
        ) else { return false }

        var total = 0
        for case let entry as URL in enumerator {
            guard let values = try? entry.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey],
            ), values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
            if total > sizeCap { return false }
        }
        return true
    }

    // MARK: - Materialization

    /// Rewrites embedded items into ordinary filesystem-backed items so the
    /// rest of the build pipeline (validation, size estimation, copy) never
    /// sees a payload: file payloads resolve directly to their file inside
    /// `assetsDirectory`; folder payloads are extracted into
    /// `stagingDirectory`. Non-embedded items pass through untouched.
    static func materialize(
        items: [CanvasItem],
        assetsDirectory: URL,
        stagingDirectory: URL,
    ) throws -> [CanvasItem] {
        try items.map { item in
            guard let assetName = item.assetName,
                  item.linkType == .copy,
                  !item.isPlaceholder
            else { return item }

            let payloadURL = assetsDirectory.appending(path: assetName)
            guard FileManager.default.fileExists(atPath: payloadURL.path) else {
                throw EmbedError.missingPayload(item.label)
            }

            var materialized = item
            switch item.kind {
            case .folder:
                let extracted = stagingDirectory.appending(path: item.id.uuidString)
                try extractArchive(at: payloadURL, to: extracted)
                materialized.sourcePath = extracted.path
            case .file, .app, .applicationsSymlink:
                materialized.sourcePath = payloadURL.path
            }
            materialized.assetName = nil
            materialized.sourceBookmark = nil
            return materialized
        }
    }

    // MARK: - Folder Archives

    /// Archives a directory's contents into LZFSE-compressed Apple Archive data.
    private static func archive(directory: URL) throws -> Data {
        let tempArchive = FileManager.default.temporaryDirectory
            .appending(path: "rilmazafone-embed-\(UUID().uuidString).aar")
        defer { try? FileManager.default.removeItem(at: tempArchive) }

        guard let keySet = ArchiveHeader.FieldKeySet(archiveFields),
              let writeStream = ArchiveByteStream.fileStream(
                  path: FilePath(tempArchive.path),
                  mode: .writeOnly,
                  options: [.create, .truncate],
                  permissions: FilePermissions(rawValue: 0o644),
              ),
              let compressStream = ArchiveByteStream.compressionStream(
                  using: .lzfse, writingTo: writeStream,
              ),
              let encodeStream = ArchiveStream.encodeStream(writingTo: compressStream)
        else { throw EmbedError.archiveFailed("could not open archive streams") }

        do {
            try encodeStream.writeDirectoryContents(
                archiveFrom: FilePath(directory.path), keySet: keySet,
            )
        } catch {
            try? encodeStream.close()
            try? compressStream.close()
            try? writeStream.close()
            throw EmbedError.archiveFailed(String(describing: error))
        }
        try encodeStream.close()
        try compressStream.close()
        try writeStream.close()

        return try Data(contentsOf: tempArchive)
    }

    /// Extracts an Apple Archive payload into `destination`, creating it.
    static func extractArchive(at archiveURL: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true,
        )

        guard let readStream = ArchiveByteStream.fileStream(
            path: FilePath(archiveURL.path),
            mode: .readOnly,
            options: [],
            permissions: FilePermissions(rawValue: 0o644),
        ),
            let decompressStream = ArchiveByteStream.decompressionStream(readingFrom: readStream),
            let decodeStream = ArchiveStream.decodeStream(readingFrom: decompressStream),
            let extractStream = ArchiveStream.extractStream(
                extractingTo: FilePath(destination.path),
                flags: [.ignoreOperationNotPermitted],
            )
        else { throw EmbedError.archiveFailed("could not open extraction streams") }

        defer {
            try? extractStream.close()
            try? decodeStream.close()
            try? decompressStream.close()
            try? readStream.close()
        }
        _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
    }
}
