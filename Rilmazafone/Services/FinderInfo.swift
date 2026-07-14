import Foundation

/// In-process replacements for the `SetFile` Command Line Tools shim, which is absent
/// on machines without Xcode / the CLT (App Review and most end users).
///
/// Two operations are needed by the DMG pipeline:
/// - Marking a file or directory invisible in Finder (`SetFile -a V`), done via
///   `URLResourceValues.isHidden`.
/// - Setting the custom-volume-icon flag on the mount root (`SetFile -a C`), done by
///   writing the `com.apple.FinderInfo` extended attribute directly.
nonisolated enum FinderInfo {
    /// Length of the `com.apple.FinderInfo` extended attribute: a 16-byte `FileInfo`/
    /// `FolderInfo` structure followed by a 16-byte `ExtendedFileInfo`/`ExtendedFolderInfo`.
    static let attributeLength = 32

    /// The `kHasCustomIcon` Finder flag (`0x0400`), stored big-endian in the
    /// `finderFlags` field at byte offset 8.
    private static let hasCustomIconFlag: UInt16 = 0x0400

    /// Byte offset of the big-endian `finderFlags` field within the FinderInfo structure.
    private static let finderFlagsOffset = 8

    /// The extended attribute name Finder uses for the FolderInfo/FileInfo blob.
    private static let attributeName = "com.apple.FinderInfo"

    // MARK: - Errors

    nonisolated enum FinderInfoError: Error, LocalizedError {
        case setAttributeFailed(path: String, errno: Int32)

        var errorDescription: String? {
            switch self {
            case let .setAttributeFailed(path, errno):
                "Failed to set FinderInfo on \(path): \(String(cString: strerror(errno)))"
            }
        }
    }

    // MARK: - Pure Core

    /// Returns a 32-byte FinderInfo blob with the `kHasCustomIcon` flag set, preserving
    /// every other byte of any `existing` FinderInfo.
    ///
    /// If `existing` is `nil` the result starts from 32 zero bytes. Input shorter than
    /// 32 bytes is zero-padded; input longer than 32 bytes is truncated (the trailing
    /// bytes are not part of the FinderInfo attribute). The flag is written big-endian
    /// into the two bytes at offsets 8–9, matching the on-disk layout Finder reads.
    static func settingCustomIconFlag(in existing: Data?) -> Data {
        var info = existing ?? Data()
        if info.count < attributeLength {
            info.append(Data(count: attributeLength - info.count))
        } else if info.count > attributeLength {
            info = info.prefix(attributeLength)
        }

        var flags = UInt16(info[info.startIndex + finderFlagsOffset]) << 8
            | UInt16(info[info.startIndex + finderFlagsOffset + 1])
        flags |= hasCustomIconFlag

        info[info.startIndex + finderFlagsOffset] = UInt8(flags >> 8)
        info[info.startIndex + finderFlagsOffset + 1] = UInt8(flags & 0xFF)

        return info
    }

    // MARK: - xattr I/O

    /// Reads the raw `com.apple.FinderInfo` extended attribute, or `nil` if absent.
    static func readFinderInfo(at path: String) -> Data? {
        let size = getxattr(path, attributeName, nil, 0, 0, 0)
        guard size > 0 else { return nil }

        var buffer = Data(count: size)
        let read = buffer.withUnsafeMutableBytes { raw in
            getxattr(path, attributeName, raw.baseAddress, size, 0, 0)
        }
        guard read >= 0 else { return nil }
        return buffer.prefix(read)
    }

    /// Sets the custom-volume-icon flag (`kHasCustomIcon`) on the item at `path`,
    /// preserving any existing FinderInfo bytes.
    static func setCustomIconFlag(at path: String) throws {
        let updated = settingCustomIconFlag(in: readFinderInfo(at: path))
        let status = updated.withUnsafeBytes { raw in
            setxattr(path, attributeName, raw.baseAddress, raw.count, 0, 0)
        }
        guard status == 0 else {
            throw FinderInfoError.setAttributeFailed(path: path, errno: errno)
        }
    }

    /// Marks the item at `url` invisible in Finder (equivalent to `SetFile -a V`).
    static func setInvisible(at url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isHidden = true
        try mutableURL.setResourceValues(values)
    }
}
