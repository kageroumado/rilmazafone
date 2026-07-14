import CoreGraphics
import Foundation
import Testing
@testable import Rilmazafone

@Suite("DSStoreWriter")
@MainActor
struct DSStoreWriterTests {
    // MARK: - File Structure

    @Test("Output has correct file magic and Bud1 header")
    func fileHeader() throws {
        let config = Self.minimalConfiguration()
        let data = try DSStoreWriter.write(configuration: config)

        // File magic: 0x00000001 at offset 0
        #expect(data.readBE32(at: 0) == 0x0000_0001)

        // Bud1 at offset 4
        #expect(data.readASCII(at: 4, count: 4) == "Bud1")

        // Bookkeeping allocator offset at offset 8
        #expect(data.readBE32(at: 8) == 0x0000_2000)

        // Bookkeeping size at offset 12
        #expect(data.readBE32(at: 12) == 0x0000_0800)
    }

    @Test("Output has correct total file size")
    func fileSize() throws {
        let config = Self.minimalConfiguration()
        let data = try DSStoreWriter.write(configuration: config)

        // Pre-allocated file: allocator base (4) + 0x2800 bookkeeping end
        #expect(data.count == 0x2804)
    }

    // MARK: - DSDB Superblock

    @Test("DSDB superblock has correct structure")
    func dsdbSuperblock() throws {
        let config = Self.minimalConfiguration()
        let data = try DSStoreWriter.write(configuration: config)

        let sb = 0x0044 // File offset for DSDB superblock

        // root = block 2 (leaf)
        #expect(data.readBE32(at: sb) == 2)
        // height = 0 (leaf only)
        #expect(data.readBE32(at: sb + 4) == 0)
        // node count = 1
        #expect(data.readBE32(at: sb + 12) == 1)
        // page size
        #expect(data.readBE32(at: sb + 16) == 0x1000)
    }

    @Test("Record count matches expected records")
    func recordCount() throws {
        var config = Self.minimalConfiguration()
        config.items = [
            CanvasItem(kind: .app, label: "MyApp.app", position: CGPoint(x: 150, y: 200)),
            CanvasItem(kind: .applicationsSymlink, label: "Applications", position: CGPoint(x: 400, y: 200)),
        ]

        let data = try DSStoreWriter.write(configuration: config)

        let sb = 0x0044
        // 3 directory records (bwsp, icvp, vSrn) + 2 item Iloc records = 5
        let recordCount = data.readBE32(at: sb + 8)
        #expect(recordCount == 5)
    }

    // MARK: - Block Address Table

    @Test("Bookkeeping block address table is correct")
    func blockAddressTable() throws {
        let config = Self.minimalConfiguration()
        let data = try DSStoreWriter.write(configuration: config)

        let bk = 0x2004 // File offset for bookkeeping block

        // Allocated block count
        #expect(data.readBE32(at: bk) == 3)

        // Block 0: bookkeeping @ 0x2000, width 11
        #expect(data.readBE32(at: bk + 8) == 0x200B)
        // Block 1: superblock @ 0x0040, width 5
        #expect(data.readBE32(at: bk + 12) == 0x0045)
        // Block 2: leaf node @ 0x1000, width 12
        #expect(data.readBE32(at: bk + 16) == 0x100C)
    }

    // MARK: - B-Tree Leaf Node

    @Test("Leaf node starts with mode 0 and correct count")
    func leafNodeHeader() throws {
        var config = Self.minimalConfiguration()
        config.items = [
            CanvasItem(kind: .app, label: "Test.app", position: CGPoint(x: 100, y: 200)),
        ]

        let data = try DSStoreWriter.write(configuration: config)

        let leaf = 0x1004 // File offset for leaf node

        // mode = 0 (leaf)
        #expect(data.readBE32(at: leaf) == 0)
        // record count: 3 directory + 1 item = 4
        #expect(data.readBE32(at: leaf + 4) == 4)
    }

    // MARK: - Record Sorting

    @Test("Records are sorted case-insensitively by filename then type code")
    func recordSorting() throws {
        var config = Self.minimalConfiguration()
        config.items = [
            CanvasItem(kind: .app, label: "Zebra.app", position: CGPoint(x: 100, y: 200)),
            CanvasItem(kind: .app, label: "alpha.app", position: CGPoint(x: 200, y: 200)),
        ]

        let data = try DSStoreWriter.write(configuration: config)

        // Parse record filenames from the leaf node to verify order
        let filenames = Self.extractRecordFilenames(from: data, at: 0x1004)

        // "." records come first (bwsp, icvp, vSrn), then "alpha.app", then "Zebra.app"
        // "." < "a" < "z" in case-insensitive ASCII
        let dotCount = filenames.filter { $0 == "." }.count
        #expect(dotCount == 3)

        let nonDot = filenames.filter { $0 != "." }
        #expect(nonDot == ["alpha.app", "Zebra.app"])
    }

    // MARK: - Iloc Records

    @Test("Iloc record encodes position with content inset adjustment")
    func ilocEncoding() throws {
        var config = Self.minimalConfiguration()
        config.items = [
            CanvasItem(kind: .app, label: "App.app", position: CGPoint(x: 150, y: 250)),
        ]

        let data = try DSStoreWriter.write(configuration: config)

        // Find the Iloc payload for "App.app" in the leaf node
        guard let payload = Self.findIlocPayload(for: "App.app", in: data, at: 0x1004) else {
            Issue.record("Could not find Iloc record for App.app")
            return
        }

        // Iloc: blob header (8 bytes) + x(4) + y(4) + sentinel(4) + sentinel(4)
        #expect(payload.readASCII(at: 0, count: 4) == "blob")
        #expect(payload.readBE32(at: 4) == 16) // blob length

        let x = payload.readBE32(at: 8)
        let y = payload.readBE32(at: 12)
        #expect(x == 150)
        // y = 250 - 10 (Finder content inset) = 240
        #expect(y == 240)

        // Sentinels
        #expect(payload.readBE32(at: 16) == 0xFFFF_FFFF)
        #expect(payload.readBE32(at: 20) == 0xFFFF_0000)
    }

    // MARK: - vSrn Record

    @Test("vSrn record encodes as long value 1")
    func vsrnEncoding() throws {
        let config = Self.minimalConfiguration()
        let data = try DSStoreWriter.write(configuration: config)

        guard let payload = Self.findRecordPayload(for: ".", typeCode: "vSrn", in: data, at: 0x1004) else {
            Issue.record("Could not find vSrn record")
            return
        }

        #expect(payload.readASCII(at: 0, count: 4) == "long")
        #expect(payload.readBE32(at: 4) == 1)
    }

    // MARK: - bwsp Record

    @Test("bwsp window bounds include title bar offset")
    func bwspWindowBounds() throws {
        var config = Self.minimalConfiguration()
        config.window = WindowConfiguration(width: 500, height: 300)
        config.windowPosition = WindowPosition(x: 100, y: 50)

        let data = try DSStoreWriter.write(configuration: config)

        guard let payload = Self.findRecordPayload(for: ".", typeCode: "bwsp", in: data, at: 0x1004) else {
            Issue.record("Could not find bwsp record")
            return
        }

        // Skip blob header (8 bytes), then parse the binary plist
        let blobSize = Int(payload.readBE32(at: 4))
        let plistData = payload.subdata(in: 8 ..< (8 + blobSize))

        let plist = try #require(PropertyListSerialization.propertyList(
            from: plistData,
            format: nil
        ) as? [String: Any])

        // Height should be 300 + 32 (title bar) = 332
        let bounds = try #require(plist["WindowBounds"] as? String)
        #expect(bounds == "{{100, 50}, {500, 332}}")

        // Sidebar/toolbar flags
        #expect(plist["ShowSidebar"] as? Bool == false)
        #expect(plist["ShowToolbar"] as? Bool == false)
        #expect(plist["ContainerShowSidebar"] as? Bool == false)
    }

    // MARK: - icvp Record

    @Test("icvp encodes icon size, text size, and grid spacing")
    func icvpBasicProperties() throws {
        var config = Self.minimalConfiguration()
        config.iconSize = 128
        config.textSize = 14
        config.gridSpacing = 80
        config.isGridSpacingAuto = false

        let data = try DSStoreWriter.write(configuration: config)

        guard let payload = Self.findRecordPayload(for: ".", typeCode: "icvp", in: data, at: 0x1004) else {
            Issue.record("Could not find icvp record")
            return
        }

        let blobSize = Int(payload.readBE32(at: 4))
        let plistData = payload.subdata(in: 8 ..< (8 + blobSize))

        let plist = try #require(PropertyListSerialization.propertyList(
            from: plistData,
            format: nil
        ) as? [String: Any])

        #expect(plist["iconSize"] as? Double == 128)
        #expect(plist["textSize"] as? Double == 14)
        #expect(plist["gridSpacing"] as? Double == 80)
        #expect(plist["arrangeBy"] as? String == "none")
    }

    @Test("icvp color background sets type 1 with RGB")
    func icvpColorBackground() throws {
        var config = Self.minimalConfiguration()
        config.background.type = .color
        config.background.color = RGBColor(red: 0.5, green: 0.6, blue: 0.7)

        let data = try DSStoreWriter.write(configuration: config)

        guard let payload = Self.findRecordPayload(for: ".", typeCode: "icvp", in: data, at: 0x1004) else {
            Issue.record("Could not find icvp record")
            return
        }

        let blobSize = Int(payload.readBE32(at: 4))
        let plistData = payload.subdata(in: 8 ..< (8 + blobSize))

        let plist = try #require(PropertyListSerialization.propertyList(
            from: plistData,
            format: nil
        ) as? [String: Any])

        #expect(plist["backgroundType"] as? Int == 1)
        #expect(plist["backgroundColorRed"] as? Double == 0.5)
        #expect(plist["backgroundColorGreen"] as? Double == 0.6)
        #expect(plist["backgroundColorBlue"] as? Double == 0.7)
    }

    @Test("icvp image background sets type 2 and embeds alias")
    func icvpImageBackground() throws {
        var config = Self.minimalConfiguration()
        config.background.type = .image

        let fakeAlias = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let data = try DSStoreWriter.write(
            configuration: config,
            backgroundAlias: fakeAlias
        )

        guard let payload = Self.findRecordPayload(for: ".", typeCode: "icvp", in: data, at: 0x1004) else {
            Issue.record("Could not find icvp record")
            return
        }

        let blobSize = Int(payload.readBE32(at: 4))
        let plistData = payload.subdata(in: 8 ..< (8 + blobSize))

        let plist = try #require(PropertyListSerialization.propertyList(
            from: plistData,
            format: nil
        ) as? [String: Any])

        #expect(plist["backgroundType"] as? Int == 2)
        #expect(plist["backgroundImageAlias"] as? Data == fakeAlias)
    }

    @Test("icvp gradient falls through to no background")
    func icvpGradientFallthrough() throws {
        var config = Self.minimalConfiguration()
        config.background.type = .gradient

        let data = try DSStoreWriter.write(configuration: config)

        guard let payload = Self.findRecordPayload(for: ".", typeCode: "icvp", in: data, at: 0x1004) else {
            Issue.record("Could not find icvp record")
            return
        }

        let blobSize = Int(payload.readBE32(at: 4))
        let plistData = payload.subdata(in: 8 ..< (8 + blobSize))

        let plist = try #require(PropertyListSerialization.propertyList(
            from: plistData,
            format: nil
        ) as? [String: Any])

        #expect(plist["backgroundType"] as? Int == 0)
    }

    // MARK: - Hidden File Positioning

    @Test("Background directory is positioned below visible area")
    func backgroundIlocPositioning() throws {
        var config = Self.minimalConfiguration()
        config.window = WindowConfiguration(width: 500, height: 300)
        config.iconSize = 64

        let fakeAlias = Data([0xDE, 0xAD])
        let data = try DSStoreWriter.write(configuration: config, backgroundAlias: fakeAlias)

        guard let payload = Self.findIlocPayload(for: ".background", in: data, at: 0x1004) else {
            Issue.record("Could not find Iloc record for .background")
            return
        }

        let x = payload.readBE32(at: 8)
        let y = payload.readBE32(at: 12)
        // Centered horizontally
        #expect(x == 250)
        // Below visible area: windowHeight(300) + iconSize(64) = 364
        #expect(y == 364)
    }

    @Test("Volume icon is positioned below visible area")
    func volumeIconIlocPositioning() throws {
        var config = Self.minimalConfiguration()
        config.window = WindowConfiguration(width: 500, height: 300)
        config.iconSize = 64
        config.volumeIcon.type = .composed

        let data = try DSStoreWriter.write(configuration: config)

        guard let payload = Self.findIlocPayload(for: ".VolumeIcon.icns", in: data, at: 0x1004) else {
            Issue.record("Could not find Iloc record for .VolumeIcon.icns")
            return
        }

        let x = payload.readBE32(at: 8)
        let y = payload.readBE32(at: 12)
        #expect(x == 250)
        #expect(y == 364)
    }

    @Test("Hidden files not included when unnecessary")
    func noHiddenIlocsWhenUnneeded() throws {
        var config = Self.minimalConfiguration()
        config.volumeIcon.type = .none

        let data = try DSStoreWriter.write(configuration: config)

        #expect(Self.findIlocPayload(for: ".background", in: data, at: 0x1004) == nil)
        #expect(Self.findIlocPayload(for: ".VolumeIcon.icns", in: data, at: 0x1004) == nil)
    }

    // MARK: - pBBk Record

    @Test("pBBk record is included when bookmark data is provided")
    func pBBkPresent() throws {
        let config = Self.minimalConfiguration()
        let bookmark = Data(repeating: 0xAB, count: 64)
        let data = try DSStoreWriter.write(configuration: config, backgroundBookmark: bookmark)

        let payload = Self.findRecordPayload(for: ".", typeCode: "pBBk", in: data, at: 0x1004)
        #expect(payload != nil)
    }

    @Test("pBBk record is absent when no bookmark data")
    func pBBkAbsent() throws {
        let config = Self.minimalConfiguration()
        let data = try DSStoreWriter.write(configuration: config)

        let payload = Self.findRecordPayload(for: ".", typeCode: "pBBk", in: data, at: 0x1004)
        #expect(payload == nil)
    }

    // MARK: - Reference File Comparison

    @Test("Output matches Python ds_store reference file")
    func referenceFileComparison() throws {
        // Reference created with Python ds_store library (v1.3.2):
        //   Volume: "TestDMG", Window: 660x400 @ (200,120)
        //   Icon size: 160, Text size: 13, Grid spacing: 100
        //   Background: none (type 0)
        //   Items: "MyApp.app" at (165,200), "Applications" at (495,200)
        let referenceURL = Bundle(for: BundleMarker.self)
            .url(forResource: "reference", withExtension: "dsstore")

        guard let referenceURL, FileManager.default.fileExists(atPath: referenceURL.path) else {
            withKnownIssue("Reference DS_Store not yet bundled") {
                Issue.record("Place reference.DS_Store in the test bundle Resources")
            }
            return
        }

        var config = DMGConfiguration()
        config.volumeName = "TestDMG"
        config.window = WindowConfiguration(width: 660, height: 400)
        config.windowPosition = WindowPosition(x: 200, y: 120)
        config.iconSize = 160
        config.textSize = 13
        config.background.type = .none
        config.volumeIcon.type = .none
        config.items = [
            CanvasItem(kind: .app, label: "MyApp.app", position: CGPoint(x: 165, y: 200)),
            CanvasItem(kind: .applicationsSymlink, label: "Applications", position: CGPoint(x: 495, y: 200)),
        ]

        let generated = try DSStoreWriter.write(configuration: config)
        let reference = try Data(contentsOf: referenceURL)

        // Both use buddy allocator but may have different block layouts,
        // so we dynamically locate the DSDB and leaf node in each file.
        let (genDSDB, genLeaf) = try Self.findOffsets(in: generated)
        let (refDSDB, refLeaf) = try Self.findOffsets(in: reference)

        // 1. File magic
        #expect(generated.readBE32(at: 0) == reference.readBE32(at: 0))
        #expect(generated.readASCII(at: 4, count: 4) == reference.readASCII(at: 4, count: 4))

        // 2. Same record count
        #expect(generated.readBE32(at: genDSDB + 8) == reference.readBE32(at: refDSDB + 8))

        // 3. Same record filenames in same sorted order
        let genFilenames = Self.extractRecordFilenames(from: generated, at: genLeaf)
        let refFilenames = Self.extractRecordFilenames(from: reference, at: refLeaf)
        #expect(genFilenames == refFilenames)

        // 4. Same Iloc positions for items (y adjusted by finderContentInset)
        for label in ["MyApp.app", "Applications"] {
            let genIloc = Self.findIlocPayload(for: label, in: generated, at: genLeaf)
            let refIloc = Self.findIlocPayload(for: label, in: reference, at: refLeaf)
            #expect(genIloc != nil, "Missing Iloc for \(label) in generated")
            #expect(refIloc != nil, "Missing Iloc for \(label) in reference")
            if let genIloc, let refIloc {
                #expect(genIloc.readBE32(at: 8) == refIloc.readBE32(at: 8), "x mismatch for \(label)")
                // Our y is 10pt less than the reference (Finder content inset compensation)
                let genY = genIloc.readBE32(at: 12)
                let refY = refIloc.readBE32(at: 12)
                #expect(genY == refY - 10, "y mismatch for \(label): generated \(genY), reference \(refY)")
            }
        }

        // 5. Same icvp properties
        let genIcvp = Self.findRecordPayload(for: ".", typeCode: "icvp", in: generated, at: genLeaf)
        let refIcvp = Self.findRecordPayload(for: ".", typeCode: "icvp", in: reference, at: refLeaf)
        #expect(genIcvp != nil, "Missing icvp in generated")
        #expect(refIcvp != nil, "Missing icvp in reference")
        if let genIcvp, let refIcvp {
            let genDict = try Self.parseBlobPlist(genIcvp)
            let refDict = try Self.parseBlobPlist(refIcvp)
            #expect(genDict["iconSize"] as? Double == refDict["iconSize"] as? Double)
            #expect(genDict["textSize"] as? Double == refDict["textSize"] as? Double)
            #expect(genDict["gridSpacing"] as? Double == refDict["gridSpacing"] as? Double)
            #expect(genDict["backgroundType"] as? Int == refDict["backgroundType"] as? Int)
        }

        // 6. Same bwsp window bounds
        let genBwsp = Self.findRecordPayload(for: ".", typeCode: "bwsp", in: generated, at: genLeaf)
        let refBwsp = Self.findRecordPayload(for: ".", typeCode: "bwsp", in: reference, at: refLeaf)
        #expect(genBwsp != nil, "Missing bwsp in generated")
        #expect(refBwsp != nil, "Missing bwsp in reference")
        if let genBwsp, let refBwsp {
            let genDict = try Self.parseBlobPlist(genBwsp)
            let refDict = try Self.parseBlobPlist(refBwsp)
            #expect(genDict["WindowBounds"] as? String == refDict["WindowBounds"] as? String)
        }
    }

    // MARK: - Helpers

    static func minimalConfiguration() -> DMGConfiguration {
        var config = DMGConfiguration()
        config.background.type = .none
        config.volumeIcon.type = .none
        return config
    }

    /// Extracts record filenames from a leaf node at the given file offset.
    static func extractRecordFilenames(from data: Data, at leafOffset: Int) -> [String] {
        var filenames: [String] = []
        var pos = leafOffset + 8 // Skip mode(4) + count(4)
        let recordCount = Int(data.readBE32(at: leafOffset + 4))

        for _ in 0 ..< recordCount {
            guard pos + 4 <= data.count else { break }
            let charCount = Int(data.readBE32(at: pos))
            pos += 4

            let byteCount = charCount * 2
            guard pos + byteCount <= data.count else { break }
            var utf16: [UInt16] = []
            for i in 0 ..< charCount {
                utf16.append(data.readBE16(at: pos + i * 2))
            }
            filenames.append(String(utf16CodeUnits: utf16, count: charCount))
            pos += byteCount

            // Skip type code (4 bytes)
            pos += 4

            // Skip payload based on type tag
            guard pos + 4 <= data.count else { break }
            let tag = data.readASCII(at: pos, count: 4)
            pos += 4

            switch tag {
            case "blob":
                let blobLen = Int(data.readBE32(at: pos))
                pos += 4 + blobLen
            case "long":
                pos += 4
            case "bool":
                pos += 1
            case "ustr":
                let strLen = Int(data.readBE32(at: pos))
                pos += 4 + strLen * 2
            default:
                break
            }
        }

        return filenames
    }

    /// Finds the raw payload (including type tag) for an Iloc record with the given filename.
    static func findIlocPayload(for filename: String, in data: Data, at leafOffset: Int) -> Data? {
        findRecordPayload(for: filename, typeCode: "Iloc", in: data, at: leafOffset)
    }

    /// Finds the raw payload (including type tag) for a record with given filename and type code.
    static func findRecordPayload(for filename: String, typeCode: String, in data: Data, at leafOffset: Int) -> Data? {
        var pos = leafOffset + 8
        let recordCount = Int(data.readBE32(at: leafOffset + 4))

        for _ in 0 ..< recordCount {
            guard pos + 4 <= data.count else { return nil }
            let charCount = Int(data.readBE32(at: pos))
            pos += 4

            let byteCount = charCount * 2
            guard pos + byteCount <= data.count else { return nil }
            var utf16: [UInt16] = []
            for i in 0 ..< charCount {
                utf16.append(data.readBE16(at: pos + i * 2))
            }
            let name = String(utf16CodeUnits: utf16, count: charCount)
            pos += byteCount

            guard pos + 4 <= data.count else { return nil }
            let code = data.readASCII(at: pos, count: 4)
            pos += 4

            guard pos + 4 <= data.count else { return nil }
            let tag = data.readASCII(at: pos, count: 4)

            let payloadStart = pos
            pos += 4

            // Calculate total payload size (tag + content) and advance pos
            let totalPayloadSize: Int
            switch tag {
            case "blob":
                let contentSize = Int(data.readBE32(at: pos))
                totalPayloadSize = 4 + 4 + contentSize
            case "long":
                totalPayloadSize = 4 + 4
            case "bool":
                totalPayloadSize = 4 + 1
            case "ustr":
                let strLen = Int(data.readBE32(at: pos))
                totalPayloadSize = 4 + 4 + strLen * 2
            default:
                return nil
            }
            pos = payloadStart + totalPayloadSize

            if name == filename, code == typeCode {
                return data.subdata(in: payloadStart ..< pos)
            }
        }

        return nil
    }

    /// Dynamically locates the DSDB superblock and B-tree leaf node in a DS_Store file
    /// by parsing the buddy allocator block address table. Supports any allocator layout.
    /// Returns (dsdbFileOffset, leafFileOffset).
    static func findOffsets(in data: Data) throws -> (dsdb: Int, leaf: Int) {
        let base = 4 // File base (after magic)

        // Bud1 header: allocator offset at base+4
        let allocOffset = Int(data.readBE32(at: base + 4))

        // Bookkeeping block: file_offset = base + allocOffset
        let bkOffset = base + allocOffset

        // Block 1 = DSDB superblock (block addresses start at bkOffset+8)
        let dsdbAddr = data.readBE32(at: bkOffset + 12)
        let dsdbOffset = base + Int(dsdbAddr & ~0x1F)

        // DSDB superblock: root block index at first 4 bytes
        let rootBlockIndex = Int(data.readBE32(at: dsdbOffset))

        // Look up root block address
        let rootAddr = data.readBE32(at: bkOffset + 8 + rootBlockIndex * 4)
        let leafOffset = base + Int(rootAddr & ~0x1F)

        return (dsdbOffset, leafOffset)
    }

    /// Parses a blob payload (tag "blob" + length + binary plist) into a dictionary.
    static func parseBlobPlist(_ payload: Data) throws -> [String: Any] {
        let blobSize = Int(payload.readBE32(at: 4))
        let plistData = payload.subdata(in: 8 ..< (8 + blobSize))
        guard let result = try PropertyListSerialization.propertyList(
            from: plistData, format: nil
        ) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return result
    }
}

// MARK: - Data Reading Helpers

extension Data {
    func readBE32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }

    func readBE16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func readASCII(at offset: Int, count: Int) -> String {
        String(bytes: self[offset ..< (offset + count)], encoding: .ascii) ?? ""
    }
}

/// Marker class for Bundle(for:) in test target
private class BundleMarker {}
