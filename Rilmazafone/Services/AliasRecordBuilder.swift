import Foundation

/// Generates classic Alias Manager records for `.DS_Store` background image references.
///
/// The `.DS_Store` `icvp` plist's `backgroundImageAlias` field expects a classic
/// Alias Manager record (the binary format used before macOS 10.6 bookmarks).
/// Modern `URL.bookmarkData()` produces a different format that Finder does not
/// recognize in this context.
///
/// The alias format is documented in Apple's legacy Alias Manager reference and
/// reverse-engineered by the `macos-alias` npm package.
nonisolated enum AliasRecordBuilder {
    enum AliasError: Error, LocalizedError {
        case fileNotFound(URL)
        case statFailed(URL)
        case volumeNameTooLong

        var errorDescription: String? {
            switch self {
            case let .fileNotFound(url):
                "File not found for alias creation: \(url.path)"
            case let .statFailed(url):
                "Could not stat file for alias: \(url.path)"
            case .volumeNameTooLong:
                "Volume name exceeds 27 characters."
            }
        }
    }

    // MARK: - Apple Epoch

    /// Seconds between Unix epoch (1970-01-01) and Apple/HFS epoch (1904-01-01).
    private static let appleEpochOffset: UInt32 = 2_082_844_800

    private static func appleDate(from date: Date) -> UInt32 {
        UInt32(clamping: Int64(date.timeIntervalSince1970) + Int64(appleEpochOffset))
    }

    // MARK: - Public API

    /// Creates a classic Alias Manager record for a background image on a mounted volume.
    ///
    /// Must be called while the volume is mounted so that `stat()` can resolve inodes.
    ///
    /// - Parameters:
    ///   - imageName: The background image filename (e.g., "background.png").
    ///   - volumeName: The actual volume name (from DMG configuration, not mount point).
    ///   - mountPoint: The mount point URL of the DMG volume (may differ from /Volumes/<name>).
    /// - Returns: Raw Alias Manager record data for embedding in icvp plist.
    static func createBackgroundAlias(
        imageName: String,
        volumeName: String,
        mountPoint: URL
    ) throws -> Data {
        let backgroundDir = mountPoint.appending(path: ".background")
        let fileURL = backgroundDir.appending(path: imageName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AliasError.fileNotFound(fileURL)
        }

        let fm = FileManager.default
        let fileAttrs = try fm.attributesOfItem(atPath: fileURL.path)
        let parentAttrs = try fm.attributesOfItem(atPath: backgroundDir.path)
        let volumeAttrs = try fm.attributesOfItem(atPath: mountPoint.path)

        guard let fileInode = fileAttrs[.systemFileNumber] as? UInt64,
              let fileCTime = fileAttrs[.creationDate] as? Date,
              let parentInode = parentAttrs[.systemFileNumber] as? UInt64,
              let volumeCTime = volumeAttrs[.creationDate] as? Date
        else {
            throw AliasError.statFailed(fileURL)
        }

        guard volumeName.utf8.count <= 27 else {
            throw AliasError.volumeNameTooLong
        }

        let parentDirName = ".background"
        // Use the canonical /Volumes/<name> path — that's what Finder sees when
        // mounting the final DMG, regardless of our build-time mount point.
        let volumePath = "/Volumes/\(volumeName)"
        let volumeRelativePath = "/.background/\(imageName)"

        return encode(AliasFields(
            volumeName: volumeName,
            volumeCreated: volumeCTime,
            volumePath: volumePath,
            parentDirName: parentDirName,
            parentDirID: UInt32(parentInode),
            filename: imageName,
            fileID: UInt32(fileInode),
            fileCreated: fileCTime,
            volumeRelativePath: volumeRelativePath
        ))
    }

    // MARK: - Alias Record Encoding

    private struct AliasFields {
        var volumeName: String
        var volumeCreated: Date
        var volumePath: String
        var parentDirName: String
        var parentDirID: UInt32
        var filename: String
        var fileID: UInt32
        var fileCreated: Date
        var volumeRelativePath: String
    }

    /// Encodes a classic Alias Manager record.
    ///
    /// Format: 150-byte header + variable-length tagged extra data + 4-byte trailer.
    private static func encode(_ fields: AliasFields) -> Data {
        let volumeName = fields.volumeName
        let volumeCreated = fields.volumeCreated
        let volumePath = fields.volumePath
        let parentDirName = fields.parentDirName
        let parentDirID = fields.parentDirID
        let filename = fields.filename
        let fileID = fields.fileID
        let fileCreated = fields.fileCreated
        let volumeRelativePath = fields.volumeRelativePath
        // Build extra data entries first to calculate total size
        var extras: [(type: Int16, data: Data)] = []

        // Type 0: parent directory name (UTF-8)
        extras.append((0, Data(parentDirName.utf8)))

        // Type 1: parent directory ID
        var parentIDData = Data()
        parentIDData.appendBigEndianUInt32(parentDirID)
        extras.append((1, parentIDData))

        // Type 2: Carbon/HFS path (colon-separated, e.g. "VolumeName:.background:filename")
        let carbonPath = "\(volumeName):\(parentDirName):\(filename)"
        extras.append((2, Data(carbonPath.utf8)))

        // Type 14: filename in UTF-16BE
        let filenameUTF16 = Array(filename.utf16)
        var type14 = Data()
        type14.appendBigEndianUInt16(UInt16(filenameUTF16.count))
        for unit in filenameUTF16 {
            type14.appendBigEndianUInt16(unit)
        }
        extras.append((14, type14))

        // Type 15: volume name in UTF-16BE
        let volNameUTF16 = Array(volumeName.utf16)
        var type15 = Data()
        type15.appendBigEndianUInt16(UInt16(volNameUTF16.count))
        for unit in volNameUTF16 {
            type15.appendBigEndianUInt16(unit)
        }
        extras.append((15, type15))

        // Type 18: volume-relative POSIX path (UTF-8)
        extras.append((18, Data(volumeRelativePath.utf8)))

        // Type 19: volume POSIX path (UTF-8)
        extras.append((19, Data(volumePath.utf8)))

        // Calculate total size
        let baseLength = 150
        let extraLength = extras.reduce(0) { total, entry in
            let padding = entry.data.count % 2
            return total + 4 + entry.data.count + padding
        }
        let trailerLength = 4
        let totalLength = baseLength + extraLength + trailerLength

        // Encode header (150 bytes)
        var buf = Data(repeating: 0, count: totalLength)

        // Offset 0: user type (0)
        writeBE32(&buf, 0, at: 0)

        // Offset 4: record size
        writeBE16(&buf, UInt16(totalLength), at: 4)

        // Offset 6: version (2)
        writeBE16(&buf, 2, at: 6)

        // Offset 8: alias kind (0 = file)
        writeBE16(&buf, 0, at: 8)

        // Offset 10: volume name (Pascal string, 1 + 27 bytes)
        let volNameBytes = Array(volumeName.utf8)
        buf[10] = UInt8(min(volNameBytes.count, 27))
        for (i, byte) in volNameBytes.prefix(27).enumerated() {
            buf[11 + i] = byte
        }

        // Offset 38: volume creation date
        writeBE32(&buf, appleDate(from: volumeCreated), at: 38)

        // Offset 42: volume signature ("H+" for HFS+/APFS)
        buf[42] = 0x48 // 'H'
        buf[43] = 0x2B // '+'

        // Offset 44: volume type (5 = other ejectable for DMG)
        writeBE16(&buf, 5, at: 44)

        // Offset 46: parent directory ID
        writeBE32(&buf, parentDirID, at: 46)

        // Offset 50: filename (Pascal string, 1 + 63 bytes)
        let fnBytes = Array(filename.utf8)
        buf[50] = UInt8(min(fnBytes.count, 63))
        for (i, byte) in fnBytes.prefix(63).enumerated() {
            buf[51 + i] = byte
        }

        // Offset 114: file number (inode)
        writeBE32(&buf, fileID, at: 114)

        // Offset 118: file creation date
        writeBE32(&buf, appleDate(from: fileCreated), at: 118)

        // Offset 122: file type code (0)
        // Offset 126: file creator code (0)
        // Already zeroed

        // Offset 130: nlvlFrom (-1)
        writeBE16(&buf, UInt16(bitPattern: -1), at: 130)

        // Offset 132: nlvlTo (-1)
        writeBE16(&buf, UInt16(bitPattern: -1), at: 132)

        // Offset 134: volume attributes
        writeBE32(&buf, 0x0000_0D02, at: 134)

        // Offset 138: volume filesystem ID (0)
        // Offset 140-149: reserved (0)
        // Already zeroed

        // Encode extra data entries (starting at offset 150)
        var pos = 150
        for entry in extras {
            writeBE16(&buf, UInt16(bitPattern: entry.type), at: pos)
            writeBE16(&buf, UInt16(entry.data.count), at: pos + 2)
            buf.replaceSubrange(pos + 4 ..< pos + 4 + entry.data.count, with: entry.data)
            pos += 4 + entry.data.count
            if entry.data.count % 2 == 1 {
                buf[pos] = 0
                pos += 1
            }
        }

        // Trailer: type -1, length 0
        writeBE16(&buf, UInt16(bitPattern: -1), at: pos)
        writeBE16(&buf, 0, at: pos + 2)

        return buf
    }

    // MARK: - Binary Helpers

    private static func writeBE32(_ data: inout Data, _ value: UInt32, at offset: Int) {
        data[offset] = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    private static func writeBE16(_ data: inout Data, _ value: UInt16, at offset: Int) {
        data[offset] = UInt8((value >> 8) & 0xFF)
        data[offset + 1] = UInt8(value & 0xFF)
    }
}
