import Foundation
import Testing
@testable import Rilmazafone

@Suite("FinderInfo")
struct FinderInfoTests {
    // MARK: - Pure Core

    @Test("Custom icon flag set in empty FinderInfo")
    func flagInEmptyInfo() {
        let info = FinderInfo.settingCustomIconFlag(in: nil)
        #expect(info.count == 32)
        #expect(info[8] == 0x04)
        #expect(info[9] == 0x00)
        // Every other byte remains zero.
        for (index, byte) in info.enumerated() where index != 8 {
            #expect(byte == 0, "byte \(index) should be zero")
        }
    }

    @Test("Existing nonzero bytes preserved")
    func preservesExistingBytes() {
        var existing = Data(count: 32)
        existing[0] = 0xAB // OSType 'type' field
        existing[4] = 0xCD // OSType 'creator' field
        existing[10] = 0xEF // location field, after the flags
        existing[31] = 0x99 // last byte of ExtendedFolderInfo

        let info = FinderInfo.settingCustomIconFlag(in: existing)
        #expect(info.count == 32)
        #expect(info[0] == 0xAB)
        #expect(info[4] == 0xCD)
        #expect(info[10] == 0xEF)
        #expect(info[31] == 0x99)
        #expect(info[8] == 0x04)
        #expect(info[9] == 0x00)
    }

    @Test("Existing flags OR-ed, not overwritten")
    func orsExistingFlags() {
        var existing = Data(count: 32)
        // kIsInvisible (0x4000) already set in the big-endian flags field.
        existing[8] = 0x40
        existing[9] = 0x00

        let info = FinderInfo.settingCustomIconFlag(in: existing)
        // 0x4000 | 0x0400 = 0x4400
        #expect(info[8] == 0x44)
        #expect(info[9] == 0x00)
    }

    @Test("Idempotent")
    func idempotent() {
        let once = FinderInfo.settingCustomIconFlag(in: nil)
        let twice = FinderInfo.settingCustomIconFlag(in: once)
        #expect(once == twice)
    }

    @Test("Output is always exactly 32 bytes")
    func alwaysThirtyTwoBytes() {
        #expect(FinderInfo.settingCustomIconFlag(in: nil).count == 32)
        #expect(FinderInfo.settingCustomIconFlag(in: Data(count: 4)).count == 32)
        #expect(FinderInfo.settingCustomIconFlag(in: Data(count: 32)).count == 32)
        #expect(FinderInfo.settingCustomIconFlag(in: Data(count: 64)).count == 32)
    }

    @Test("Flag bytes are big-endian at offsets 8-9")
    func bigEndianFlag() {
        let info = FinderInfo.settingCustomIconFlag(in: nil)
        let flags = UInt16(info[8]) << 8 | UInt16(info[9])
        #expect(flags == 0x0400)
    }

    @Test("Longer-than-32-byte input truncated to attribute length")
    func truncatesOverlongInput() {
        var overlong = Data(count: 64)
        overlong[40] = 0xFF // beyond the FinderInfo attribute
        let info = FinderInfo.settingCustomIconFlag(in: overlong)
        #expect(info.count == 32)
    }

    // MARK: - xattr Round-trip

    @Test("xattr round-trip on a temp directory")
    func xattrRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "rilmazafone-finderinfo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(FinderInfo.readFinderInfo(at: dir.path) == nil)

        try FinderInfo.setCustomIconFlag(at: dir.path)

        let read = try #require(FinderInfo.readFinderInfo(at: dir.path))
        #expect(read.count == 32)
        #expect(read[8] == 0x04)
        #expect(read[9] == 0x00)

        // Applying again preserves the flag (idempotent through the syscalls).
        try FinderInfo.setCustomIconFlag(at: dir.path)
        let reread = try #require(FinderInfo.readFinderInfo(at: dir.path))
        #expect(reread == read)
    }

    @Test("xattr round-trip preserves pre-existing FinderInfo bytes")
    func xattrPreservesExisting() throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "rilmazafone-finderinfo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed a FinderInfo blob with a distinctive byte outside the flags field.
        var seed = Data(count: 32)
        seed[20] = 0x7E
        let status = seed.withUnsafeBytes { raw in
            setxattr(dir.path, "com.apple.FinderInfo", raw.baseAddress, raw.count, 0, 0)
        }
        #expect(status == 0)

        try FinderInfo.setCustomIconFlag(at: dir.path)

        let read = try #require(FinderInfo.readFinderInfo(at: dir.path))
        #expect(read[20] == 0x7E)
        #expect(read[8] == 0x04)
    }

    @Test("setInvisible marks a file hidden")
    func setInvisibleHidesFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "rilmazafone-hidden-\(UUID().uuidString).icns")
        try Data("icon".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        try FinderInfo.setInvisible(at: file)

        let values = try file.resourceValues(forKeys: [.isHiddenKey])
        #expect(values.isHidden == true)
    }
}
