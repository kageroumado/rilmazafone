import CoreGraphics
import Foundation

/// Parses `.DS_Store` files in pure Swift — the inverse of ``DSStoreWriter``.
///
/// The `.DS_Store` format is a buddy-allocator-managed B-tree used by Finder
/// to persist per-directory view settings and icon positions. This reader
/// walks the allocator's block table, locates the `DSDB` tree via the table
/// of contents, and traverses both leaf-only stores and multi-level trees
/// with internal nodes.
///
/// All integers are **big-endian**. Values are returned exactly as stored:
/// icon positions are Finder icon-view coordinates (the writer subtracts
/// ``DSStoreWriter/finderContentInset`` when encoding), and window bounds are
/// the Finder window *frame* including the title bar (the writer adds
/// ``DSStoreWriter/finderTitleBarHeight``). Callers mapping back to canvas
/// coordinates must invert those adjustments.
///
/// Error policy: structural corruption (bad magic, out-of-bounds blocks,
/// truncated nodes, cycles) throws ``DSStoreReader/ReadError``. Payload-level
/// oddities in otherwise well-formed records (an unparseable embedded plist,
/// a short `Iloc` blob, an unknown record type) are skipped so that a store
/// with unfamiliar records still yields everything it can.
nonisolated enum DSStoreReader {
    // MARK: - Public Types

    /// Semantic content extracted from a `.DS_Store` file.
    struct Contents: Equatable {
        /// Icon positions keyed by filename, from `Iloc` records.
        /// Coordinates are raw Finder icon-view values.
        var iconPositions: [String: CGPoint] = [:]

        /// Finder window frame from the `bwsp` record, including title bar.
        var windowBounds: CGRect?

        /// Sidebar width from the `bwsp` record, when present.
        var sidebarWidth: Double?

        /// Icon size in points from the `icvp` record.
        var iconSize: Double?

        /// Label text size in points from the `icvp` record.
        var textSize: Double?

        /// Icon grid spacing from the `icvp` record.
        var gridSpacing: Double?

        /// Background style from the `icvp` record.
        var backgroundKind: BackgroundKind?

        /// Raw classic Alias Manager record from `icvp`'s
        /// `backgroundImageAlias`, when the background is an image.
        var backgroundImageAliasData: Data?

        /// Raw macOS bookmark data from the `pBBk` record, when present.
        var backgroundImageBookmarkData: Data?
    }

    /// Background style stored in the `icvp` record's `backgroundType`.
    enum BackgroundKind: Equatable {
        /// Type 0: default (no custom background).
        case `default`
        /// Type 1: solid color.
        case color(red: Double, green: Double, blue: Double)
        /// Type 2: background image (see `backgroundImageAliasData`).
        case image
    }

    /// Structural parse failures. See the type-level error policy.
    enum ReadError: Error, Equatable {
        /// The data ends before a required structure is complete.
        case truncated
        /// The leading file magic is not `0x00000001` or the allocator
        /// header does not start with `Bud1`.
        case invalidMagic
        /// The allocator header fields are inconsistent.
        case invalidHeader
        /// The table of contents has no `DSDB` entry.
        case missingDSDB
        /// A block number has no valid entry in the allocator block table.
        case invalidBlockNumber(UInt32)
        /// A block's address places it (partly) outside the file.
        case invalidBlockAddress(UInt32)
        /// A record carries a data-type tag not in the format's vocabulary,
        /// making its length — and every record after it — unknowable.
        case unknownDataType(String)
        /// The B-tree nests deeper than ``maxTreeDepth``.
        case treeTooDeep
        /// A B-tree node is referenced more than once (a cycle).
        case nodeCycle
    }

    // MARK: - Public API

    /// Parses a complete `.DS_Store` file.
    ///
    /// - Parameter data: The raw file contents.
    /// - Returns: The semantic content of all recognized records.
    /// - Throws: ``ReadError`` when the allocator or B-tree structure is
    ///   malformed. Never crashes on arbitrary input.
    static func read(_ data: Data) throws -> Contents {
        let bytes = [UInt8](data)
        var cursor = Cursor(bytes: bytes)

        try readHeader(&cursor)
        let allocator = try readAllocator(bytes: bytes, cursor: &cursor)

        guard let dsdbBlock = allocator.directory[Layout.treeName] else {
            throw ReadError.missingDSDB
        }
        let superblock = try readSuperblock(block: dsdbBlock, allocator: allocator)

        var contents = Contents()
        var visited = Set<UInt32>()
        try walkNode(
            block: superblock.rootBlock,
            allocator: allocator,
            depth: 0,
            visited: &visited,
            contents: &contents,
        )
        return contents
    }

    // MARK: - Constants

    /// Maximum accepted B-tree nesting; Finder trees are at most a few levels.
    static let maxTreeDepth = 64

    private enum Layout {
        static let fileMagic: UInt32 = 0x0000_0001
        static let allocatorMagic = "Bud1"
        /// File offset of the allocator base; all block addresses are
        /// relative to this.
        static let allocatorBase = 4
        /// A block address encodes `offset | log2(size)` in its low 5 bits.
        static let blockWidthMask: UInt32 = 0x1F
        /// The block address table is padded to a multiple of 256 entries.
        static let blockTableGranularity = 256
        static let treeName = "DSDB"
    }

    private enum StructType {
        static let iconLocation = "Iloc"
        static let browserWindowSettings = "bwsp"
        static let iconViewProperties = "icvp"
        static let backgroundBookmark = "pBBk"
    }

    // MARK: - Bounds-Checked Cursor

    /// A byte cursor whose every read is bounds-checked against an upper
    /// limit — the whole buffer by default, or a block's extent when sliced
    /// via ``init(bytes:range:)``.
    private struct Cursor {
        let bytes: [UInt8]
        var position: Int
        let limit: Int

        init(bytes: [UInt8]) {
            self.bytes = bytes
            self.position = 0
            self.limit = bytes.count
        }

        /// A cursor confined to `range`, which must lie within `bytes`.
        init(bytes: [UInt8], range: Range<Int>) {
            self.bytes = bytes
            self.position = range.lowerBound
            self.limit = range.upperBound
        }

        mutating func seek(to offset: Int) throws {
            guard offset >= 0, offset <= limit else {
                throw ReadError.truncated
            }
            position = offset
        }

        mutating func readUInt8() throws -> UInt8 {
            guard position < limit else { throw ReadError.truncated }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func readBE16() throws -> UInt16 {
            guard position <= limit - 2 else { throw ReadError.truncated }
            defer { position += 2 }
            return UInt16(bytes[position]) << 8 | UInt16(bytes[position + 1])
        }

        mutating func readBE32() throws -> UInt32 {
            guard position <= limit - 4 else { throw ReadError.truncated }
            defer { position += 4 }
            return UInt32(bytes[position]) << 24
                | UInt32(bytes[position + 1]) << 16
                | UInt32(bytes[position + 2]) << 8
                | UInt32(bytes[position + 3])
        }

        mutating func readData(count: Int) throws -> Data {
            guard count >= 0, position <= limit - count else {
                throw ReadError.truncated
            }
            defer { position += count }
            return Data(bytes[position ..< position + count])
        }

        mutating func readASCII(count: Int) throws -> String {
            let data = try readData(count: count)
            guard let string = String(data: data, encoding: .ascii) else {
                throw ReadError.truncated
            }
            return string
        }

        mutating func readUTF16BE(codeUnits: Int) throws -> String {
            guard codeUnits >= 0, position <= limit - codeUnits * 2 else {
                throw ReadError.truncated
            }
            var units = [UInt16]()
            units.reserveCapacity(codeUnits)
            for _ in 0 ..< codeUnits {
                try units.append(readBE16())
            }
            return String(utf16CodeUnits: units, count: codeUnits)
        }
    }

    // MARK: - Allocator

    private struct Allocator {
        /// The entire file, retained for block-scoped cursors.
        let bytes: [UInt8]
        /// Block addresses (`offset | width`) indexed by block number.
        let blockAddresses: [UInt32]
        /// Table of contents: name → block number.
        let directory: [String: UInt32]

        /// Returns a cursor confined to a block's extent, validating that
        /// the whole block lies inside the file.
        func blockCursor(_ block: UInt32) throws -> Cursor {
            guard block < blockAddresses.count else {
                throw ReadError.invalidBlockNumber(block)
            }
            let address = blockAddresses[Int(block)]
            guard address != 0 else {
                throw ReadError.invalidBlockNumber(block)
            }
            let offset = Int(address & ~Layout.blockWidthMask)
            let width = Int(address & Layout.blockWidthMask)
            let start = Layout.allocatorBase + offset
            let size = 1 << width
            guard size <= bytes.count, start <= bytes.count - size else {
                throw ReadError.invalidBlockAddress(address)
            }
            return Cursor(bytes: bytes, range: start ..< start + size)
        }
    }

    private static func readHeader(_ cursor: inout Cursor) throws {
        guard try cursor.readBE32() == Layout.fileMagic,
              try cursor.readASCII(count: 4) == Layout.allocatorMagic else {
            throw ReadError.invalidMagic
        }
    }

    private static func readAllocator(
        bytes: [UInt8],
        cursor: inout Cursor,
    ) throws -> Allocator {
        let bookkeepingOffset = try cursor.readBE32()
        let bookkeepingSize = try cursor.readBE32()
        let bookkeepingOffsetCopy = try cursor.readBE32()
        guard bookkeepingOffset == bookkeepingOffsetCopy, bookkeepingSize > 0 else {
            throw ReadError.invalidHeader
        }

        try cursor.seek(to: Layout.allocatorBase + Int(bookkeepingOffset))
        let blockCount = try cursor.readBE32()
        _ = try cursor.readBE32()

        // The address table is padded with zero entries to a multiple of 256.
        // A hostile count cannot over-allocate: every entry is read through
        // the bounds-checked cursor before being stored.
        let granularity = Layout.blockTableGranularity
        let paddedCount = (Int(blockCount) + granularity - 1) / granularity * granularity
        var addresses = [UInt32]()
        addresses.reserveCapacity(min(Int(blockCount), bytes.count / 4))
        for index in 0 ..< paddedCount {
            let address = try cursor.readBE32()
            if index < Int(blockCount) {
                addresses.append(address)
            }
        }

        var directory = [String: UInt32]()
        let directoryCount = try cursor.readBE32()
        for _ in 0 ..< directoryCount {
            let nameLength = try cursor.readUInt8()
            let name = try cursor.readASCII(count: Int(nameLength))
            let block = try cursor.readBE32()
            directory[name] = block
        }

        return Allocator(
            bytes: bytes,
            blockAddresses: addresses,
            directory: directory,
        )
    }

    // MARK: - B-Tree

    private struct Superblock {
        let rootBlock: UInt32
        let treeHeight: UInt32
    }

    private static func readSuperblock(
        block: UInt32,
        allocator: Allocator,
    ) throws -> Superblock {
        var cursor = try allocator.blockCursor(block)
        let rootBlock = try cursor.readBE32()
        let treeHeight = try cursor.readBE32()
        guard treeHeight <= maxTreeDepth else { throw ReadError.treeTooDeep }
        return Superblock(rootBlock: rootBlock, treeHeight: treeHeight)
    }

    private static func walkNode(
        block: UInt32,
        allocator: Allocator,
        depth: Int,
        visited: inout Set<UInt32>,
        contents: inout Contents,
    ) throws {
        guard depth <= maxTreeDepth else { throw ReadError.treeTooDeep }
        guard visited.insert(block).inserted else { throw ReadError.nodeCycle }

        var cursor = try allocator.blockCursor(block)
        let rightmostChild = try cursor.readBE32()
        let recordCount = try cursor.readBE32()

        if rightmostChild == 0 {
            for _ in 0 ..< recordCount {
                try readRecord(&cursor, into: &contents)
            }
        } else {
            for _ in 0 ..< recordCount {
                let child = try cursor.readBE32()
                try walkNode(
                    block: child,
                    allocator: allocator,
                    depth: depth + 1,
                    visited: &visited,
                    contents: &contents,
                )
                try readRecord(&cursor, into: &contents)
            }
            try walkNode(
                block: rightmostChild,
                allocator: allocator,
                depth: depth + 1,
                visited: &visited,
                contents: &contents,
            )
        }
    }

    // MARK: - Records

    /// A decoded record value; the cases mirror the format's data-type tags.
    private enum RecordValue {
        case long(UInt32)
        case shor(UInt32)
        case bool(Bool)
        case blob(Data)
        case type(String)
        case ustr(String)
        case comp(UInt64)
        case dutc(UInt64)
    }

    private static func readRecord(
        _ cursor: inout Cursor,
        into contents: inout Contents,
    ) throws {
        let nameLength = try cursor.readBE32()
        let name = try cursor.readUTF16BE(codeUnits: Int(nameLength))
        let structType = try cursor.readASCII(count: 4)
        let value = try readValue(&cursor)
        interpret(name: name, structType: structType, value: value, into: &contents)
    }

    /// Reads one tagged value, consuming exactly its encoded length so that
    /// unknown record types never desync the record walk.
    private static func readValue(_ cursor: inout Cursor) throws -> RecordValue {
        let tag = try cursor.readASCII(count: 4)
        switch tag {
        case "long":
            return try .long(cursor.readBE32())
        case "shor":
            return try .shor(cursor.readBE32())
        case "bool":
            return try .bool(cursor.readUInt8() != 0)
        case "blob":
            let length = try cursor.readBE32()
            return try .blob(cursor.readData(count: Int(length)))
        case "type":
            return try .type(cursor.readASCII(count: 4))
        case "ustr":
            let codeUnits = try cursor.readBE32()
            return try .ustr(cursor.readUTF16BE(codeUnits: Int(codeUnits)))
        case "comp", "dutc":
            let high = try cursor.readBE32()
            let low = try cursor.readBE32()
            let value = UInt64(high) << 32 | UInt64(low)
            return tag == "comp" ? .comp(value) : .dutc(value)
        default:
            throw ReadError.unknownDataType(tag)
        }
    }

    // MARK: - Semantic Interpretation

    private static func interpret(
        name: String,
        structType: String,
        value: RecordValue,
        into contents: inout Contents,
    ) {
        guard case let .blob(blob) = value else { return }

        switch structType {
        case StructType.iconLocation:
            if let position = decodeIconLocation(blob) {
                contents.iconPositions[name] = position
            }
        case StructType.browserWindowSettings where name == ".":
            applyWindowSettings(blob, to: &contents)
        case StructType.iconViewProperties where name == ".":
            applyIconViewProperties(blob, to: &contents)
        case StructType.backgroundBookmark where name == ".":
            contents.backgroundImageBookmarkData = blob
        default:
            break
        }
    }

    /// Iloc blob: x(u32), y(u32), then 8 bytes of padding sentinels.
    private static func decodeIconLocation(_ blob: Data) -> CGPoint? {
        guard blob.count >= 8 else { return nil }
        var cursor = Cursor(bytes: [UInt8](blob))
        guard let x = try? cursor.readBE32(), let y = try? cursor.readBE32() else {
            return nil
        }
        return CGPoint(
            x: CGFloat(Int32(bitPattern: x)),
            y: CGFloat(Int32(bitPattern: y)),
        )
    }

    private static func applyWindowSettings(_ blob: Data, to contents: inout Contents) {
        guard let plist = dictionary(fromPlist: blob) else { return }
        if let boundsString = plist["WindowBounds"] as? String {
            let rect = NSRectFromString(boundsString)
            if rect != .zero {
                contents.windowBounds = rect
            }
        }
        if let width = plist["SidebarWidth"] as? NSNumber {
            contents.sidebarWidth = width.doubleValue
        }
    }

    private static func applyIconViewProperties(_ blob: Data, to contents: inout Contents) {
        guard let plist = dictionary(fromPlist: blob) else { return }

        if let iconSize = plist["iconSize"] as? NSNumber {
            contents.iconSize = iconSize.doubleValue
        }
        if let textSize = plist["textSize"] as? NSNumber {
            contents.textSize = textSize.doubleValue
        }
        if let gridSpacing = plist["gridSpacing"] as? NSNumber {
            contents.gridSpacing = gridSpacing.doubleValue
        }

        switch (plist["backgroundType"] as? NSNumber)?.intValue {
        case 0:
            contents.backgroundKind = .default
        case 1:
            contents.backgroundKind = .color(
                red: (plist["backgroundColorRed"] as? NSNumber)?.doubleValue ?? 1,
                green: (plist["backgroundColorGreen"] as? NSNumber)?.doubleValue ?? 1,
                blue: (plist["backgroundColorBlue"] as? NSNumber)?.doubleValue ?? 1,
            )
        case 2:
            contents.backgroundKind = .image
            contents.backgroundImageAliasData = plist["backgroundImageAlias"] as? Data
        default:
            break
        }
    }

    private static func dictionary(fromPlist data: Data) -> [String: Any]? {
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        return plist as? [String: Any]
    }
}
