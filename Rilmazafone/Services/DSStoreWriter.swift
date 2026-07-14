import AppKit
import Foundation

/// Generates `.DS_Store` files in pure Swift.
///
/// The `.DS_Store` format is a buddy-allocator-managed B-tree used by Finder
/// to persist per-directory view settings and icon positions. For DMG use cases
/// with fewer than ~30 files, the B-tree fits in a single leaf node and the
/// allocator structure is minimal.
///
/// All integers are **big-endian**. The canonical reference is the Python
/// `ds_store` library and the Kaitai Struct spec.
nonisolated enum DSStoreWriter {
    // MARK: - Public API

    /// Generates a complete `.DS_Store` file.
    ///
    /// - Parameters:
    ///   - configuration: The DMG configuration defining layout and items.
    ///   - backgroundAlias: Optional classic Alias Manager record for icvp background reference.
    ///   - backgroundBookmark: Optional macOS Bookmark data for pBBk record (modern Finder).
    /// - Returns: Binary data for the `.DS_Store` file.
    static func write(
        configuration: DMGConfiguration,
        backgroundAlias: Data? = nil,
        backgroundBookmark: Data? = nil
    ) throws -> Data {
        // Build all records, then sort them
        var records = try buildRecords(
            configuration: configuration,
            backgroundAlias: backgroundAlias,
            backgroundBookmark: backgroundBookmark
        )
        records.sort()

        // Serialize records into a B-tree leaf node
        let leafData = serializeLeafNode(records: records)

        // Wrap in buddy allocator structure
        return buildAllocatorFile(
            btreeNodeData: leafData,
            recordCount: records.count
        )
    }

    // MARK: - Record Types

    /// A single `.DS_Store` record (key + value).
    private struct Record: Comparable {
        let filename: String
        let typeCode: FourCharCode
        let payload: Data

        /// Records are sorted by (lowercased filename, type code).
        static func < (lhs: Record, rhs: Record) -> Bool {
            let lName = lhs.filename.lowercased()
            let rName = rhs.filename.lowercased()
            if lName != rName { return lName < rName }
            return lhs.typeCode < rhs.typeCode
        }

        static func == (lhs: Record, rhs: Record) -> Bool {
            lhs.filename.lowercased() == rhs.filename.lowercased()
                && lhs.typeCode == rhs.typeCode
        }
    }

    /// Four-character codes used as record type identifiers.
    private enum FourCharCode: String, Comparable {
        case iloc = "Iloc"
        case bwsp
        case icvp
        case pBBk
        case vSrn

        static func < (lhs: FourCharCode, rhs: FourCharCode) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// Data type tags that precede record payloads.
    private enum DataTypeTag: String {
        case blob
        case long
        case bool
        case ustr
    }

    // MARK: - Record Builders

    private static func buildRecords(
        configuration: DMGConfiguration,
        backgroundAlias: Data?,
        backgroundBookmark: Data?
    ) throws -> [Record] {
        var records: [Record] = []

        // Per-directory records (keyed to ".")
        try records.append(bwspRecord(configuration: configuration))
        try records.append(icvpRecord(
            configuration: configuration,
            backgroundAlias: backgroundAlias
        ))

        // pBBk: background bookmark for modern Finder (macOS 12+)
        if let bookmark = backgroundBookmark {
            records.append(Record(
                filename: ".",
                typeCode: .pBBk,
                payload: encodeBlob(bookmark)
            ))
        }

        records.append(vsrnRecord())

        // Per-file Iloc records (adjusted for Finder's content inset)
        for item in configuration.items {
            records.append(ilocRecord(
                filename: item.label,
                x: Int32(item.position.x),
                y: Int32(item.position.y - finderContentInset)
            ))
        }

        // Hidden files (.background, .VolumeIcon.icns) are invisible via
        // `SetFile -a V` and dot-prefix, but users with "Show Hidden Files"
        // enabled will still see them. Position them below the visible
        // content area so they require scrolling to reach.
        let hiddenY = Int32(configuration.window.height + configuration.iconSize)
        let hiddenX = Int32(configuration.window.width / 2)

        if backgroundAlias != nil || backgroundBookmark != nil {
            records.append(ilocRecord(filename: ".background", x: hiddenX, y: hiddenY))
        }
        if configuration.volumeIcon.type != .none {
            records.append(ilocRecord(filename: ".VolumeIcon.icns", x: hiddenX, y: hiddenY))
        }

        return records
    }

    /// Iloc record: icon position. 16 bytes: x(u32), y(u32), 0xFFFFFFFF, 0xFFFF0000.
    private static func ilocRecord(
        filename: String,
        x: Int32,
        y: Int32
    ) -> Record {
        var data = Data(capacity: 16)
        data.appendBigEndianUInt32(UInt32(bitPattern: x))
        data.appendBigEndianUInt32(UInt32(bitPattern: y))
        data.appendBigEndianUInt32(0xFFFF_FFFF) // Sentinel: no horizontal padding
        data.appendBigEndianUInt32(0xFFFF_0000) // Sentinel: no vertical padding

        return Record(
            filename: filename,
            typeCode: .iloc,
            payload: encodeBlob(data)
        )
    }

    /// Standard macOS Finder title bar height for `.titled` style mask.
    ///
    /// The bwsp `WindowBounds` stores the window **frame** size, which includes
    /// the title bar. The canvas designs for content-area dimensions, so we add
    /// this offset to ensure the Finder content area matches the canvas.
    /// ``DSStoreReader`` clients invert this when mapping back to the canvas.
    static let finderTitleBarHeight: CGFloat = 32

    /// Finder's icon view applies an internal top inset within the content area.
    /// Iloc y-positions must be reduced by this amount so icons render at the
    /// intended canvas position. ``DSStoreReader`` clients invert this when
    /// mapping back to the canvas.
    static let finderContentInset: CGFloat = 10

    /// bwsp record: browser window settings as a binary plist.
    private static func bwspRecord(
        configuration: DMGConfiguration
    ) throws -> Record {
        let left = configuration.windowPosition.x
        let top = configuration.windowPosition.y
        let width = Int(configuration.window.width)
        let height = Int(configuration.window.height + finderTitleBarHeight)

        let plist: [String: Any] = [
            "ContainerShowSidebar": false,
            "ShowSidebar": false,
            "ShowStatusBar": false,
            "ShowTabView": false,
            "ShowToolbar": false,
            "WindowBounds": "{{\(left), \(top)}, {\(width), \(height)}}",
        ]

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )

        return Record(
            filename: ".",
            typeCode: .bwsp,
            payload: encodeBlob(plistData)
        )
    }

    /// icvp record: icon view properties as a binary plist.
    private static func icvpRecord(
        configuration: DMGConfiguration,
        backgroundAlias: Data?
    ) throws -> Record {
        var plist: [String: Any] = [
            "viewOptionsVersion": 1,
            "iconSize": Double(configuration.iconSize),
            "textSize": Double(configuration.textSize),
            "labelOnBottom": true,
            "showIconPreview": true,
            "showItemInfo": false,
            "gridSpacing": Double(configuration.effectiveGridSpacing),
            "gridOffsetX": 0.0,
            "gridOffsetY": 0.0,
            "arrangeBy": "none",
        ]

        switch configuration.background.type {
        case .none:
            plist["backgroundType"] = 0

        case .color:
            plist["backgroundType"] = 1
            plist["backgroundColorRed"] = Double(configuration.background.color.red)
            plist["backgroundColorGreen"] = Double(configuration.background.color.green)
            plist["backgroundColorBlue"] = Double(configuration.background.color.blue)

        case .gradient:
            // Gradient gets composited into a PNG by BuildManager, which
            // overrides the type to .image before calling DSStoreWriter.
            // If we reach here directly, treat as no background.
            plist["backgroundType"] = 0

        case .image:
            plist["backgroundType"] = 2
            plist["backgroundColorRed"] = 1.0
            plist["backgroundColorGreen"] = 1.0
            plist["backgroundColorBlue"] = 1.0
            if let alias = backgroundAlias {
                plist["backgroundImageAlias"] = alias
            }
        }

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )

        return Record(
            filename: ".",
            typeCode: .icvp,
            payload: encodeBlob(plistData)
        )
    }

    /// vSrn record: view style. Always 1 (icon view).
    private static func vsrnRecord() -> Record {
        Record(
            filename: ".",
            typeCode: .vSrn,
            payload: encodeLong(1)
        )
    }

    // MARK: - Data Type Encoding

    /// Encodes a blob value: 4-byte "blob" tag + 4-byte length + raw data.
    private static func encodeBlob(_ data: Data) -> Data {
        var result = Data()
        result.appendASCII("blob")
        result.appendBigEndianUInt32(UInt32(data.count))
        result.append(data)
        return result
    }

    /// Encodes a long value: 4-byte "long" tag + 4-byte big-endian value.
    private static func encodeLong(_ value: UInt32) -> Data {
        var result = Data()
        result.appendASCII("long")
        result.appendBigEndianUInt32(value)
        return result
    }

    // MARK: - Record Serialization

    /// Serializes a single record into its binary representation.
    private static func serializeRecord(_ record: Record) -> Data {
        var data = Data()

        // Filename: length (u32) + UTF-16BE chars
        let utf16 = Array(record.filename.utf16)
        data.appendBigEndianUInt32(UInt32(utf16.count))
        for codeUnit in utf16 {
            data.appendBigEndianUInt16(codeUnit)
        }

        // Type code: 4 ASCII bytes
        data.appendASCII(record.typeCode.rawValue)

        // Payload (already includes data type tag + value)
        data.append(record.payload)

        return data
    }

    // MARK: - B-Tree Serialization

    /// Serializes records into a single leaf node.
    /// Leaf format: mode(u32=0) + count(u32) + record data.
    private static func serializeLeafNode(records: [Record]) -> Data {
        var data = Data()

        // mode = 0 (leaf node)
        data.appendBigEndianUInt32(0)
        // record count
        data.appendBigEndianUInt32(UInt32(records.count))

        for record in records {
            data.append(serializeRecord(record))
        }

        return data
    }

    // MARK: - Buddy Allocator File Construction

    /// Builds the complete `.DS_Store` file wrapping the B-tree in a buddy allocator.
    ///
    /// Uses a fixed block layout matching the proven structure from the ds-store npm
    /// library's `DSStore-clean` template. The key insight is that block addresses encode
    /// `offset | width` where width occupies the low 5 bits, so all block offsets must
    /// be 32-byte aligned.
    ///
    /// Block table:
    /// - Block 0: Bookkeeping info   @ allocator offset 0x2000, width 11 (2048 bytes)
    /// - Block 1: DSDB superblock    @ allocator offset 0x0040, width 5  (32 bytes)
    /// - Block 2: B-tree leaf node   @ allocator offset 0x1000, width 12 (4096 bytes)
    private static func buildAllocatorFile(
        btreeNodeData: Data,
        recordCount: Int
    ) -> Data {
        // All "allocator offsets" are relative to file offset 4 (the allocator base).
        // File offset = allocator offset + 4.

        // Pre-allocate zeroed file. Bookkeeping ends at allocator offset 0x2800.
        let fileSize = 0x2804 // 0x2800 + 4 byte base
        var file = Data(repeating: 0, count: fileSize)

        // ---- File magic ----
        writeBE32(&file, 0x0000_0001, at: 0)

        // ---- Bud1 header (file offset 4, 32 bytes) ----
        writeASCII(&file, "Bud1", at: 4)
        writeBE32(&file, 0x0000_2000, at: 8) // bookkeeping allocator offset
        writeBE32(&file, 0x0000_0800, at: 12) // bookkeeping size (2048)
        writeBE32(&file, 0x0000_2000, at: 16) // bookkeeping offset (copy)
        // Bytes 20-35 remain zero

        // ---- DSDB superblock (file offset 0x44, allocator offset 0x40) ----
        let sb = 0x0044
        writeBE32(&file, 2, at: sb) // root = block 2 (leaf)
        writeBE32(&file, 0, at: sb + 4) // height = 0 (leaf only)
        writeBE32(&file, UInt32(recordCount), at: sb + 8) // record count
        writeBE32(&file, 1, at: sb + 12) // node count = 1
        writeBE32(&file, 0x1000, at: sb + 16) // page size

        // ---- B-tree leaf node (file offset 0x1004, allocator offset 0x1000) ----
        copyBytes(&file, btreeNodeData, at: 0x1004)

        // ---- Bookkeeping block (file offset 0x2004, allocator offset 0x2000) ----
        var bk = Data()

        bk.appendBigEndianUInt32(3) // 3 allocated blocks
        bk.appendBigEndianUInt32(0) // unknown (always 0)

        // Block address table: 256 entries (offset | width)
        bk.appendBigEndianUInt32(0x200B) // block 0: bookkeeping @ 0x2000, width 11
        bk.appendBigEndianUInt32(0x0045) // block 1: superblock  @ 0x0040, width 5
        bk.appendBigEndianUInt32(0x100C) // block 2: leaf node   @ 0x1000, width 12
        for _ in 3 ..< 256 {
            bk.appendBigEndianUInt32(0)
        }

        // Directory: "DSDB" → block 1 (superblock)
        bk.appendBigEndianUInt32(1) // 1 directory entry
        bk.append(UInt8(4)) // name length
        bk.appendASCII("DSDB") // name
        bk.appendBigEndianUInt32(1) // block index

        // Free lists: 32 buckets, all empty (sufficient for read-only DMG)
        for _ in 0 ..< 32 {
            bk.appendBigEndianUInt32(0)
        }

        copyBytes(&file, bk, at: 0x2004)

        return file
    }

    // MARK: - Binary Write Helpers

    private static func writeBE32(_ data: inout Data, _ value: UInt32, at offset: Int) {
        data[offset] = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    private static func writeASCII(_ data: inout Data, _ string: String, at offset: Int) {
        for (i, byte) in string.utf8.enumerated() {
            data[offset + i] = byte
        }
    }

    private static func copyBytes(_ data: inout Data, _ source: Data, at offset: Int) {
        data.replaceSubrange(offset ..< (offset + source.count), with: source)
    }
}

// MARK: - Data Helpers

nonisolated extension Data {
    mutating func appendBigEndianUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        append(Data(bytes: &bigEndian, count: 4))
    }

    mutating func appendBigEndianUInt16(_ value: UInt16) {
        var bigEndian = value.bigEndian
        append(Data(bytes: &bigEndian, count: 2))
    }

    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
