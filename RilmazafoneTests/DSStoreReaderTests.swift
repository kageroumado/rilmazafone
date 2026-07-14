import CoreGraphics
import Foundation
import Testing
@testable import Rilmazafone

@Suite("DSStoreReader")
struct DSStoreReaderTests {
    // MARK: - Round-Trip: DSStoreWriter Output

    @Test
    func `Round-trips a minimal configuration`() throws {
        let config = Self.minimalConfiguration()
        let contents = try DSStoreReader.read(DSStoreWriter.write(configuration: config))

        #expect(contents.iconPositions.isEmpty)
        #expect(contents.windowBounds == CGRect(x: 200, y: 120, width: 660, height: 432))
        #expect(contents.iconSize == 160)
        #expect(contents.textSize == 13)
        #expect(contents.gridSpacing == 100)
        #expect(contents.backgroundKind == .default)
        #expect(contents.backgroundImageAliasData == nil)
        #expect(contents.backgroundImageBookmarkData == nil)
        #expect(contents.sidebarWidth == nil)
    }

    @Test
    func `Round-trips item positions exactly (modulo Finder content inset)`() throws {
        var config = Self.minimalConfiguration()
        config.items = [
            CanvasItem(kind: .app, label: "MyApp.app", position: CGPoint(x: 150, y: 200)),
            CanvasItem(kind: .applicationsSymlink, label: "Applications", position: CGPoint(x: 400, y: 200)),
            CanvasItem(kind: .file, label: "README.txt", position: CGPoint(x: 275, y: 320)),
        ]

        let contents = try DSStoreReader.read(DSStoreWriter.write(configuration: config))

        #expect(contents.iconPositions.count == 3)
        for item in config.items {
            let expected = CGPoint(
                x: item.position.x,
                y: item.position.y - DSStoreWriter.finderContentInset,
            )
            #expect(contents.iconPositions[item.label] == expected)
        }
    }

    @Test
    func `Round-trips window bounds exactly (modulo Finder title bar)`() throws {
        var config = Self.minimalConfiguration()
        config.window = WindowConfiguration(width: 500, height: 300)
        config.windowPosition = WindowPosition(x: 100, y: 50)

        let contents = try DSStoreReader.read(DSStoreWriter.write(configuration: config))

        let expected = CGRect(
            x: 100,
            y: 50,
            width: 500,
            height: 300 + DSStoreWriter.finderTitleBarHeight,
        )
        #expect(contents.windowBounds == expected)
    }

    @Test
    func `Round-trips icon size, text size, and grid spacing exactly`() throws {
        var config = Self.minimalConfiguration()
        config.iconSize = 128
        config.textSize = 14
        config.gridSpacing = 80
        config.isGridSpacingAuto = false

        let contents = try DSStoreReader.read(DSStoreWriter.write(configuration: config))

        #expect(contents.iconSize == 128)
        #expect(contents.textSize == 14)
        #expect(contents.gridSpacing == 80)
    }

    @Test
    func `Round-trips a color background`() throws {
        var config = Self.minimalConfiguration()
        config.background.type = .color
        config.background.color = RGBColor(red: 0.5, green: 0.6, blue: 0.7)

        let contents = try DSStoreReader.read(DSStoreWriter.write(configuration: config))

        #expect(contents.backgroundKind == .color(red: 0.5, green: 0.6, blue: 0.7))
    }

    @Test
    func `Round-trips an image background with byte-exact alias and bookmark`() throws {
        var config = Self.minimalConfiguration()
        config.background.type = .image
        config.window = WindowConfiguration(width: 500, height: 300)
        config.iconSize = 64

        let alias = Data((0 ..< 300).map { UInt8($0 % 251) })
        let bookmark = Data((0 ..< 128).map { UInt8(($0 &* 7) % 253) })
        let data = try DSStoreWriter.write(
            configuration: config,
            backgroundAlias: alias,
            backgroundBookmark: bookmark,
        )

        let contents = try DSStoreReader.read(data)

        #expect(contents.backgroundKind == .image)
        #expect(contents.backgroundImageAliasData == alias)
        #expect(contents.backgroundImageBookmarkData == bookmark)
        #expect(contents.iconPositions[".background"] == CGPoint(x: 250, y: 364))
    }

    @Test
    func `Gradient background round-trips as default (writer fallthrough)`() throws {
        var config = Self.minimalConfiguration()
        config.background.type = .gradient

        let contents = try DSStoreReader.read(DSStoreWriter.write(configuration: config))

        #expect(contents.backgroundKind == .default)
    }

    // MARK: - Fixture: Python ds_store Reference

    @Test
    func `Parses the Python ds_store reference fixture`() throws {
        let data = try Self.fixture(named: "reference")
        let contents = try DSStoreReader.read(data)

        // Written by Python ds_store 1.3.2 without inset compensation,
        // so positions are stored verbatim.
        #expect(contents.iconPositions["MyApp.app"] == CGPoint(x: 165, y: 200))
        #expect(contents.iconPositions["Applications"] == CGPoint(x: 495, y: 200))
        #expect(contents.windowBounds == CGRect(x: 200, y: 120, width: 660, height: 432))
        #expect(contents.iconSize == 160)
        #expect(contents.textSize == 13)
        #expect(contents.gridSpacing == 100)
        #expect(contents.backgroundKind == .default)
    }

    // MARK: - Fixture: Finder-Written Third-Party DMG

    @Test
    func `Parses a Finder-written .DS_Store from the CodeEdit DMG`() throws {
        // Extracted from CodeEdit.dmg (github.com/CodeEditApp/CodeEdit,
        // built with create-dmg, which drives Finder via AppleScript).
        // Contains an unknown `pBB0` record that must be skipped gracefully.
        let data = try Self.fixture(named: "thirdparty-codeedit")
        let contents = try DSStoreReader.read(data)

        #expect(contents.iconPositions["CodeEdit.app"] == CGPoint(x: 170, y: 210))
        #expect(contents.iconPositions["Applications"] == CGPoint(x: 530, y: 210))
        #expect(contents.iconPositions[".background"] == CGPoint(x: 999, y: 100))
        #expect(contents.windowBounds == CGRect(x: 200, y: 442, width: 699, height: 518))
        #expect(contents.iconSize == 128)
        #expect(contents.textSize == 16)
        #expect(contents.gridSpacing == 100)
        #expect(contents.backgroundKind == .image)
        #expect(contents.backgroundImageAliasData?.count == 762)

        let bookmark = try #require(contents.backgroundImageBookmarkData)
        #expect(bookmark.prefix(4) == Data("book".utf8))
    }

    // MARK: - Internal Nodes

    @Test
    func `Walks a two-level tree with an internal node`() throws {
        let store = Self.makeTwoLevelStore()
        let contents = try DSStoreReader.read(store)

        #expect(contents.iconPositions.count == 3)
        #expect(contents.iconPositions["Alpha.app"] == CGPoint(x: 10, y: 20))
        #expect(contents.iconPositions["Beta.app"] == CGPoint(x: 30, y: 40))
        #expect(contents.iconPositions["Gamma.app"] == CGPoint(x: 50, y: 60))
    }

    @Test
    func `Every data type in the skip table is consumed without desync`() throws {
        var records: [Data] = []
        records.append(Self.record(name: "a", type: "xxx1", value: Self.boolValue(true)))
        records.append(Self.record(name: "b", type: "xxx2", value: Self.compValue(0x0102_0304_0506_0708)))
        records.append(Self.record(name: "c", type: "xxx3", value: Self.dutcValue(0x1122_3344_5566_7788)))
        records.append(Self.record(name: "d", type: "xxx4", value: Self.longValue(7)))
        records.append(Self.record(name: "e", type: "xxx5", value: Self.shorValue(3)))
        records.append(Self.record(name: "f", type: "xxx6", value: Self.typeValue("icnv")))
        records.append(Self.record(name: "g", type: "xxx7", value: Self.ustrValue("hello")))
        records.append(Self.record(name: "h", type: "xxx8", value: Self.blobValue(Data([1, 2, 3]))))
        records.append(Self.ilocRecord(name: "zzz.app", x: 42, y: 24))

        let store = Self.makeLeafOnlyStore(records: records)
        let contents = try DSStoreReader.read(store)

        #expect(contents.iconPositions == ["zzz.app": CGPoint(x: 42, y: 24)])
    }

    // MARK: - Malformed Input

    @Test
    func `Empty and tiny inputs throw`() {
        #expect(throws: DSStoreReader.ReadError.self) {
            try DSStoreReader.read(Data())
        }
        #expect(throws: DSStoreReader.ReadError.self) {
            try DSStoreReader.read(Data([0x00, 0x00, 0x00, 0x01]))
        }
    }

    @Test
    func `Corrupted file magic throws`() throws {
        var data = try DSStoreWriter.write(configuration: Self.minimalConfiguration())
        data[0] = 0xFF
        #expect(throws: DSStoreReader.ReadError.invalidMagic) {
            try DSStoreReader.read(data)
        }
    }

    @Test
    func `Corrupted Bud1 signature throws`() throws {
        var data = try DSStoreWriter.write(configuration: Self.minimalConfiguration())
        data[5] = UInt8(ascii: "X")
        #expect(throws: DSStoreReader.ReadError.invalidMagic) {
            try DSStoreReader.read(data)
        }
    }

    @Test
    func `Out-of-bounds block address throws`() throws {
        var data = try DSStoreWriter.write(configuration: Self.minimalConfiguration())
        // Block 2 (the leaf) table entry lives at bookkeeping + 8 + 2 * 4.
        Self.patchBE32(&data, 0xFFFF_E00C, at: 0x2004 + 8 + 8)
        #expect(throws: DSStoreReader.ReadError.self) {
            try DSStoreReader.read(data)
        }
    }

    @Test
    func `Unallocated (zero) block address throws`() throws {
        var data = try DSStoreWriter.write(configuration: Self.minimalConfiguration())
        Self.patchBE32(&data, 0, at: 0x2004 + 8 + 8)
        #expect(throws: DSStoreReader.ReadError.invalidBlockNumber(2)) {
            try DSStoreReader.read(data)
        }
    }

    @Test
    func `Cycle-inducing node pointers throw`() throws {
        let store = Self.makeTwoLevelStore(cycleRoot: true)
        #expect(throws: DSStoreReader.ReadError.nodeCycle) {
            try DSStoreReader.read(store)
        }
    }

    @Test
    func `Oversized record count throws instead of hanging or crashing`() throws {
        var data = try DSStoreWriter.write(configuration: Self.minimalConfiguration())
        // Leaf node record count lives at file offset 0x1004 + 4. The walk
        // fails on the zero padding (unknown tag) or block exhaustion.
        Self.patchBE32(&data, 0xFFFF_FFFF, at: 0x1004 + 4)
        #expect(throws: DSStoreReader.ReadError.self) {
            try DSStoreReader.read(data)
        }
    }

    @Test
    func `Unknown data-type tag throws`() throws {
        var data = try DSStoreWriter.write(configuration: Self.minimalConfiguration())
        let tag = Data("blob".utf8)
        let range = try #require(data.range(of: tag))
        data.replaceSubrange(range, with: Data("zzzz".utf8))
        #expect(throws: DSStoreReader.ReadError.unknownDataType("zzzz")) {
            try DSStoreReader.read(data)
        }
    }

    @Test
    func `Truncated prefixes throw or parse to the full contents`() throws {
        let data = try DSStoreWriter.write(configuration: Self.configurationWithItems())
        let full = try DSStoreReader.read(data)

        // The bookkeeping block sits at the file tail, so almost every prefix
        // fails structurally; the few that keep all referenced blocks intact
        // must yield the complete contents.
        for length in stride(from: 0, to: data.count, by: 199) {
            let prefix = data.prefix(length)
            if let partial = try? DSStoreReader.read(Data(prefix)) {
                #expect(partial == full, "Prefix of \(length) bytes parsed differently")
            }
        }
    }

    @Test
    func `Deterministic single-byte corruption never crashes`() throws {
        let sources: [Data] = try [
            DSStoreWriter.write(
                configuration: Self.configurationWithItems(),
                backgroundAlias: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            ),
            Self.fixture(named: "thirdparty-codeedit"),
        ]

        for source in sources {
            for offset in stride(from: 0, to: source.count, by: 97) {
                var mutated = source
                mutated[offset] ^= 0xB5
                _ = try? DSStoreReader.read(mutated)
            }
        }
    }

    @Test
    func `Missing DSDB directory entry throws`() throws {
        var data = try DSStoreWriter.write(configuration: Self.minimalConfiguration())
        // The TOC name "DSDB" starts after the 256-entry block table:
        // bookkeeping(0x2004) + count/unknown(8) + table(1024) + entryCount(4) + nameLength(1).
        let nameOffset = 0x2004 + 8 + 1_024 + 4 + 1
        #expect(data.readASCII(at: nameOffset, count: 4) == "DSDB")
        data[nameOffset] = UInt8(ascii: "X")
        #expect(throws: DSStoreReader.ReadError.missingDSDB) {
            try DSStoreReader.read(data)
        }
    }

    // MARK: - Configuration Helpers

    private static func minimalConfiguration() -> DMGConfiguration {
        var config = DMGConfiguration()
        config.background.type = .none
        config.volumeIcon.type = .none
        return config
    }

    private static func configurationWithItems() -> DMGConfiguration {
        var config = minimalConfiguration()
        config.items = [
            CanvasItem(kind: .app, label: "MyApp.app", position: CGPoint(x: 165, y: 200)),
            CanvasItem(kind: .applicationsSymlink, label: "Applications", position: CGPoint(x: 495, y: 200)),
        ]
        return config
    }

    private static func fixture(named name: String) throws -> Data {
        let url = try #require(
            Bundle(for: ReaderBundleMarker.self).url(forResource: name, withExtension: "dsstore"),
            "Fixture \(name).dsstore missing from test bundle",
        )
        return try Data(contentsOf: url)
    }

    // MARK: - Synthetic Store Builders

    private static func patchBE32(_ data: inout Data, _ value: UInt32, at offset: Int) {
        data[data.startIndex + offset] = UInt8((value >> 24) & 0xFF)
        data[data.startIndex + offset + 1] = UInt8((value >> 16) & 0xFF)
        data[data.startIndex + offset + 2] = UInt8((value >> 8) & 0xFF)
        data[data.startIndex + offset + 3] = UInt8(value & 0xFF)
    }

    private static func record(name: String, type: String, value: Data) -> Data {
        var data = Data()
        let utf16 = Array(name.utf16)
        data.appendBigEndianUInt32(UInt32(utf16.count))
        for unit in utf16 {
            data.appendBigEndianUInt16(unit)
        }
        data.appendASCII(type)
        data.append(value)
        return data
    }

    private static func ilocRecord(name: String, x: UInt32, y: UInt32) -> Data {
        var blob = Data()
        blob.appendBigEndianUInt32(x)
        blob.appendBigEndianUInt32(y)
        blob.appendBigEndianUInt32(0xFFFF_FFFF)
        blob.appendBigEndianUInt32(0xFFFF_0000)
        return record(name: name, type: "Iloc", value: blobValue(blob))
    }

    private static func blobValue(_ content: Data) -> Data {
        var data = Data()
        data.appendASCII("blob")
        data.appendBigEndianUInt32(UInt32(content.count))
        data.append(content)
        return data
    }

    private static func longValue(_ value: UInt32) -> Data {
        var data = Data()
        data.appendASCII("long")
        data.appendBigEndianUInt32(value)
        return data
    }

    private static func shorValue(_ value: UInt32) -> Data {
        var data = Data()
        data.appendASCII("shor")
        data.appendBigEndianUInt32(value)
        return data
    }

    private static func boolValue(_ value: Bool) -> Data {
        var data = Data()
        data.appendASCII("bool")
        data.append(value ? 1 : 0)
        return data
    }

    private static func typeValue(_ code: String) -> Data {
        var data = Data()
        data.appendASCII("type")
        data.appendASCII(code)
        return data
    }

    private static func ustrValue(_ string: String) -> Data {
        var data = Data()
        data.appendASCII("ustr")
        let utf16 = Array(string.utf16)
        data.appendBigEndianUInt32(UInt32(utf16.count))
        for unit in utf16 {
            data.appendBigEndianUInt16(unit)
        }
        return data
    }

    private static func compValue(_ value: UInt64) -> Data {
        var data = Data()
        data.appendASCII("comp")
        data.appendBigEndianUInt32(UInt32(value >> 32))
        data.appendBigEndianUInt32(UInt32(value & 0xFFFF_FFFF))
        return data
    }

    private static func dutcValue(_ value: UInt64) -> Data {
        var data = Data()
        data.appendASCII("dutc")
        data.appendBigEndianUInt32(UInt32(value >> 32))
        data.appendBigEndianUInt32(UInt32(value & 0xFFFF_FFFF))
        return data
    }

    /// Builds a complete store whose B-tree is a single leaf holding the
    /// given records. Layout mirrors DSStoreWriter's fixed block plan.
    private static func makeLeafOnlyStore(records: [Data]) -> Data {
        var leaf = Data()
        leaf.appendBigEndianUInt32(0)
        leaf.appendBigEndianUInt32(UInt32(records.count))
        for record in records {
            leaf.append(record)
        }
        return assembleStore(
            treeBlocks: [(blockNumber: 2, address: 0x100C, node: leaf)],
            rootBlock: 2,
            height: 0,
            recordCount: UInt32(records.count),
            nodeCount: 1,
        )
    }

    /// Builds a store with an internal root (block 2) over two leaves
    /// (blocks 3 and 4). With `cycleRoot`, the root's rightmost-child
    /// pointer targets the root itself.
    private static func makeTwoLevelStore(cycleRoot: Bool = false) -> Data {
        var leafA = Data()
        leafA.appendBigEndianUInt32(0)
        leafA.appendBigEndianUInt32(1)
        leafA.append(ilocRecord(name: "Alpha.app", x: 10, y: 20))

        var leafB = Data()
        leafB.appendBigEndianUInt32(0)
        leafB.appendBigEndianUInt32(1)
        leafB.append(ilocRecord(name: "Gamma.app", x: 50, y: 60))

        var root = Data()
        root.appendBigEndianUInt32(cycleRoot ? 2 : 4) // rightmost child
        root.appendBigEndianUInt32(1)
        root.appendBigEndianUInt32(3) // left child
        root.append(ilocRecord(name: "Beta.app", x: 30, y: 40))

        return assembleStore(
            treeBlocks: [
                (blockNumber: 2, address: 0x1008, node: root),
                (blockNumber: 3, address: 0x1108, node: leafA),
                (blockNumber: 4, address: 0x1208, node: leafB),
            ],
            rootBlock: 2,
            height: 1,
            recordCount: 3,
            nodeCount: 3,
        )
    }

    /// Assembles a full buddy-allocator file: header, DSDB superblock
    /// (block 1 @ 0x40), tree blocks as given, and the bookkeeping block
    /// (block 0 @ 0x2000) with address table, TOC, and empty free lists.
    private static func assembleStore(
        treeBlocks: [(blockNumber: Int, address: UInt32, node: Data)],
        rootBlock: UInt32,
        height: UInt32,
        recordCount: UInt32,
        nodeCount: UInt32,
    ) -> Data {
        var file = Data(repeating: 0, count: 0x2804)

        patchBE32(&file, 0x0000_0001, at: 0)
        file.replaceSubrange(4 ..< 8, with: Data("Bud1".utf8))
        patchBE32(&file, 0x0000_2000, at: 8)
        patchBE32(&file, 0x0000_0800, at: 12)
        patchBE32(&file, 0x0000_2000, at: 16)

        // DSDB superblock (block 1 @ allocator offset 0x40, file 0x44)
        patchBE32(&file, rootBlock, at: 0x44)
        patchBE32(&file, height, at: 0x48)
        patchBE32(&file, recordCount, at: 0x4C)
        patchBE32(&file, nodeCount, at: 0x50)
        patchBE32(&file, 0x1000, at: 0x54)

        for block in treeBlocks {
            let offset = 4 + Int(block.address & ~0x1F)
            file.replaceSubrange(offset ..< offset + block.node.count, with: block.node)
        }

        // Bookkeeping block (block 0 @ allocator offset 0x2000, file 0x2004)
        let blockCount = 2 + treeBlocks.count
        var bk = Data()
        bk.appendBigEndianUInt32(UInt32(blockCount))
        bk.appendBigEndianUInt32(0)

        var table = [UInt32](repeating: 0, count: 256)
        table[0] = 0x200B
        table[1] = 0x0045
        for block in treeBlocks {
            table[block.blockNumber] = block.address
        }
        for address in table {
            bk.appendBigEndianUInt32(address)
        }

        bk.appendBigEndianUInt32(1)
        bk.append(4)
        bk.appendASCII("DSDB")
        bk.appendBigEndianUInt32(1)

        for _ in 0 ..< 32 {
            bk.appendBigEndianUInt32(0)
        }

        file.replaceSubrange(0x2004 ..< 0x2004 + bk.count, with: bk)
        return file
    }
}

/// Marker class for Bundle(for:) in the test target.
private class ReaderBundleMarker {}
