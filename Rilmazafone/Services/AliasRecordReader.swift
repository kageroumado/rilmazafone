import Foundation

/// Extracts the background image path from classic Alias Manager records.
///
/// This is the minimal inverse of ``AliasRecordBuilder``: given the
/// `backgroundImageAlias` bytes from a `.DS_Store` `icvp` plist, it recovers
/// the volume-relative path of the alias target (e.g. `.background/bg.tiff`).
///
/// Third-party DMG tools (create-dmg, DMG Canvas, appdmg) emit varying subsets
/// of the alias record's extended info, so the parser tries several signals in
/// order of reliability: the POSIX path record, the Carbon (colon-separated)
/// path record, and finally the file name plus parent folder name fields.
/// Parsing is fully defensive — malformed or truncated input yields `nil`,
/// never a crash.
nonisolated enum AliasRecordReader {
    // MARK: - Format Layout

    private enum Layout {
        /// Fixed header length of a version-2 alias record.
        static let headerLength = 150
        /// Offset of the 16-bit format version field.
        static let versionOffset = 6
        /// Offset of the volume name Pascal string (1 length byte + 27 bytes).
        static let volumeNameOffset = 10
        static let volumeNameCapacity = 27
        /// Offset of the file name Pascal string (1 length byte + 63 bytes).
        static let fileNameOffset = 50
        static let fileNameCapacity = 63
        /// The only alias record version this reader understands.
        static let supportedVersion: UInt16 = 2
    }

    /// Extended info record tags relevant to path recovery.
    private enum ExtraTag: Int16 {
        case parentDirectoryName = 0
        case carbonPath = 2
        case unicodeFileName = 14
        case posixPath = 18
        case posixVolumePath = 19
        case end = -1
    }

    /// The conventional hidden directory holding DMG background images.
    static let backgroundDirectoryName = ".background"

    /// Directory names scanned by the import fallback, in preference order.
    private static let backgroundDirectoryNames = [".background", ".bg"]

    /// File extensions accepted by the directory-scan fallback.
    private static let imageExtensions: Set<String> = [
        "png", "tiff", "tif", "jpg", "jpeg", "gif", "bmp", "heic",
    ]

    // MARK: - Public API

    /// Returns the volume-relative path of the alias target, or `nil` if the
    /// record cannot be parsed.
    ///
    /// The result never has a leading slash (e.g. `.background/background.tiff`),
    /// ready to be resolved against a mount point.
    ///
    /// - Parameter data: Raw classic Alias Manager record bytes, typically the
    ///   `backgroundImageAlias` value from a `.DS_Store` `icvp` plist.
    static func volumeRelativePath(from data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= Layout.headerLength,
              readBE16(bytes, at: Layout.versionOffset) == Layout.supportedVersion
        else { return nil }

        let extras = parseExtras(bytes)

        if let posix = decodeString(extras[.posixPath]),
           let path = normalizePOSIXPath(posix, volumePath: decodeString(extras[.posixVolumePath])) {
            return path
        }

        if let carbon = decodeString(extras[.carbonPath]),
           let path = normalizeCarbonPath(carbon) {
            return path
        }

        let fileName = decodeUTF16Counted(extras[.unicodeFileName])
            ?? pascalString(bytes, at: Layout.fileNameOffset, capacity: Layout.fileNameCapacity)
        guard let fileName, !fileName.isEmpty else { return nil }

        let parentName = decodeString(extras[.parentDirectoryName]) ?? backgroundDirectoryName
        return cleanRelativePath("\(parentName)/\(fileName)")
    }

    /// Returns the first image file in the volume's background directory, or
    /// `nil` if none exists.
    ///
    /// This is the import flow's documented fallback for when alias parsing
    /// fails entirely: scan `.background/` (and `.bg/`, another convention)
    /// for the first file with a known image extension, in lexicographic order.
    ///
    /// - Parameter mountRoot: The root URL of the mounted DMG volume.
    static func firstImage(inBackgroundDirectoryOf mountRoot: URL) -> URL? {
        let fm = FileManager.default
        for directoryName in backgroundDirectoryNames {
            let directory = mountRoot.appending(path: directoryName)
            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
            ) else { continue }

            let match = entries
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .first { url in
                    guard imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                    return values?.isRegularFile == true
                }
            if let match { return match }
        }
        return nil
    }

    // MARK: - Extended Info Records

    /// Walks the tagged extra records starting after the fixed header.
    ///
    /// Tolerates records that end early: a truncated entry or missing end tag
    /// simply terminates the walk with whatever was recovered so far.
    private static func parseExtras(_ bytes: [UInt8]) -> [ExtraTag: [UInt8]] {
        var extras: [ExtraTag: [UInt8]] = [:]
        var pos = Layout.headerLength

        while pos + 4 <= bytes.count {
            let tag = Int16(bitPattern: readBE16(bytes, at: pos))
            let length = Int(readBE16(bytes, at: pos + 2))
            if tag == ExtraTag.end.rawValue { break }

            let payloadEnd = pos + 4 + length
            guard payloadEnd <= bytes.count else { break }

            if let known = ExtraTag(rawValue: tag), extras[known] == nil {
                extras[known] = Array(bytes[(pos + 4) ..< payloadEnd])
            }
            pos = payloadEnd + (length % 2)
        }
        return extras
    }

    // MARK: - Path Normalization

    /// Normalizes a POSIX path record (tag 18) to a volume-relative path.
    ///
    /// Observed forms: volume-relative with a leading slash
    /// (`/.background/bg.png`, our builder and create-dmg) and absolute
    /// (`/Volumes/Name/.background/bg.png`, some Finder-written records).
    private static func normalizePOSIXPath(_ path: String, volumePath: String?) -> String? {
        var relative = path
        if let volumePath, volumePath.count > 1, relative.hasPrefix(volumePath + "/") {
            relative = String(relative.dropFirst(volumePath.count + 1))
        } else if relative.hasPrefix("/Volumes/") {
            let components = relative.split(separator: "/").map(String.init)
            guard components.count > 2 else { return nil }
            relative = components.dropFirst(2).joined(separator: "/")
        }
        return cleanRelativePath(relative)
    }

    /// Normalizes a Carbon path record (tag 2) to a volume-relative path.
    ///
    /// Observed forms: `Volume:.background:bg.png` (appdmg, our builder) and
    /// `/:Volumes:Volume:.background:bg.tiff` (DMG Canvas).
    private static func normalizeCarbonPath(_ path: String) -> String? {
        var components = path
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)

        if let first = components.first, first.isEmpty || first == "/" {
            components.removeFirst()
            if components.first == "Volumes" {
                components.removeFirst()
            }
        }
        guard !components.isEmpty else { return nil }
        components.removeFirst()
        return cleanRelativePath(components.joined(separator: "/"))
    }

    /// Strips empty and `.` components, rejects traversal, and requires a
    /// non-empty relative result.
    private static func cleanRelativePath(_ path: String) -> String? {
        let components = path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return components.joined(separator: "/")
    }

    // MARK: - String Decoding

    /// Decodes bytes as UTF-8, falling back to MacRoman for legacy records.
    private static func decodeString(_ bytes: [UInt8]?) -> String? {
        guard let bytes, !bytes.isEmpty else { return nil }
        let data = Data(bytes)
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .macOSRoman)
    }

    /// Reads a Pascal string (length byte + payload) at a fixed header offset.
    private static func pascalString(_ bytes: [UInt8], at offset: Int, capacity: Int) -> String? {
        guard offset < bytes.count else { return nil }
        let length = Int(bytes[offset])
        guard length > 0, length <= capacity, offset + 1 + length <= bytes.count else { return nil }
        return decodeString(Array(bytes[(offset + 1) ..< (offset + 1 + length)]))
    }

    /// Decodes a counted UTF-16BE string (tag 14/15 payload layout).
    private static func decodeUTF16Counted(_ bytes: [UInt8]?) -> String? {
        guard let bytes, bytes.count >= 2 else { return nil }
        let unitCount = Int(readBE16(bytes, at: 0))
        guard unitCount > 0, 2 + unitCount * 2 <= bytes.count else { return nil }
        let payload = Data(bytes[2 ..< (2 + unitCount * 2)])
        return String(data: payload, encoding: .utf16BigEndian)
    }

    // MARK: - Binary Helpers

    private static func readBE16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
}
