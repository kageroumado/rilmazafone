import Foundation
import Testing
@testable import Rilmazafone

@Suite("AliasRecordBuilder")
struct AliasRecordBuilderTests {
    // MARK: - Encode Tests (via public createBackgroundAlias indirectly, or by testing encode directly)

    // Since `encode` is private, we test the binary format through known byte patterns
    // in the output. We create a temporary volume structure for createBackgroundAlias.

    @Test("Alias record header has correct magic bytes")
    func headerStructure() throws {
        let data = try createTestAlias()

        // Offset 0: user type = 0
        #expect(data.readBE32(at: 0) == 0)

        // Offset 4: total size (UInt16 BE)
        let totalSize = data.readBE16(at: 4)
        #expect(Int(totalSize) == data.count)

        // Offset 6: version = 2
        #expect(data.readBE16(at: 6) == 2)

        // Offset 8: alias kind = 0 (file)
        #expect(data.readBE16(at: 8) == 0)
    }

    @Test("Volume name is stored as Pascal string at offset 10")
    func volumeNamePascalString() throws {
        let data = try createTestAlias(volumeName: "TestVol")

        // Offset 10: Pascal string length byte
        #expect(data[10] == 7) // "TestVol" = 7 bytes

        // Offset 11-17: "TestVol"
        let nameBytes = Array(data[11 ..< 18])
        #expect(nameBytes == Array("TestVol".utf8))

        // Rest of 28-byte field should be zero-padded
        for i in 18 ..< 38 {
            #expect(data[i] == 0, "Byte at offset \(i) should be zero-padded")
        }
    }

    @Test("Volume signature is H+ at offset 42-43")
    func volumeSignature() throws {
        let data = try createTestAlias()

        #expect(data[42] == 0x48) // 'H'
        #expect(data[43] == 0x2B) // '+'
    }

    @Test("Volume type is 5 (ejectable) at offset 44")
    func volumeType() throws {
        let data = try createTestAlias()

        #expect(data.readBE16(at: 44) == 5)
    }

    @Test("Filename is stored as Pascal string at offset 50")
    func filenamePascalString() throws {
        let data = try createTestAlias(imageName: "bg.png")

        #expect(data[50] == 6) // "bg.png" = 6 bytes

        let nameBytes = Array(data[51 ..< 57])
        #expect(nameBytes == Array("bg.png".utf8))
    }

    @Test("nlvlFrom and nlvlTo are -1 at offsets 130-133")
    func nlvlFields() throws {
        let data = try createTestAlias()

        #expect(data.readBE16(at: 130) == 0xFFFF) // -1 as UInt16
        #expect(data.readBE16(at: 132) == 0xFFFF) // -1 as UInt16
    }

    @Test("Volume attributes at offset 134")
    func volumeAttributes() throws {
        let data = try createTestAlias()

        #expect(data.readBE32(at: 134) == 0x0000_0D02)
    }

    @Test("Extra data trailer is type -1 length 0")
    func trailer() throws {
        let data = try createTestAlias()

        // Last 4 bytes: type(-1) + length(0)
        let trailerOffset = data.count - 4
        #expect(data.readBE16(at: trailerOffset) == 0xFFFF)
        #expect(data.readBE16(at: trailerOffset + 2) == 0)
    }

    @Test("Carbon path uses colon separators (type 2 extra)")
    func carbonPathFormat() throws {
        let data = try createTestAlias(volumeName: "MyVol", imageName: "bg.png")

        // Find type 2 extra entry
        guard let entry = findExtraEntry(type: 2, in: data) else {
            Issue.record("Type 2 extra entry not found")
            return
        }

        let path = String(data: entry, encoding: .utf8)
        #expect(path == "MyVol:.background:bg.png")
    }

    @Test("Volume-relative POSIX path (type 18 extra)")
    func volumeRelativePath() throws {
        let data = try createTestAlias(imageName: "background.png")

        guard let entry = findExtraEntry(type: 18, in: data) else {
            Issue.record("Type 18 extra entry not found")
            return
        }

        let path = String(data: entry, encoding: .utf8)
        #expect(path == "/.background/background.png")
    }

    @Test("Volume POSIX path (type 19 extra)")
    func volumePosixPath() throws {
        let data = try createTestAlias(volumeName: "TestVol")

        guard let entry = findExtraEntry(type: 19, in: data) else {
            Issue.record("Type 19 extra entry not found")
            return
        }

        let path = String(data: entry, encoding: .utf8)
        #expect(path == "/Volumes/TestVol")
    }

    @Test("Odd-length extra data is padded to even alignment")
    func oddLengthPadding() throws {
        // "abc" is 3 bytes (odd) — should be padded to 4
        let data = try createTestAlias(imageName: "abc")

        // Verify total size is even
        #expect(data.count % 2 == 0)

        // Verify the overall structure parses correctly by checking trailer
        let trailerOffset = data.count - 4
        #expect(data.readBE16(at: trailerOffset) == 0xFFFF)
    }

    @Test("Volume name exceeding 27 bytes throws error")
    func volumeNameTooLong() throws {
        let longName = String(repeating: "A", count: 28)

        #expect(throws: AliasRecordBuilder.AliasError.self) {
            try createTestAlias(volumeName: longName)
        }
    }

    @Test("Volume name exactly 27 bytes succeeds")
    func volumeNameExact27() throws {
        let name = String(repeating: "A", count: 27)
        let data = try createTestAlias(volumeName: name)

        #expect(data[10] == 27)
    }

    // MARK: - Helpers

    /// Creates a test alias by setting up a temporary directory structure that mimics a mounted volume.
    private func createTestAlias(
        volumeName: String = "TestVol",
        imageName: String = "background.png"
    ) throws -> Data {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "rilmazafone-alias-test-\(UUID().uuidString)")
        let backgroundDir = tmpDir.appending(path: ".background")
        let imageFile = backgroundDir.appending(path: imageName)

        try FileManager.default.createDirectory(at: backgroundDir, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageFile) // fake PNG

        defer {
            try? FileManager.default.removeItem(at: tmpDir)
        }

        return try AliasRecordBuilder.createBackgroundAlias(
            imageName: imageName,
            volumeName: volumeName,
            mountPoint: tmpDir
        )
    }

    /// Finds an extra data entry by type code in the alias record (entries start at offset 150).
    private func findExtraEntry(type targetType: Int16, in data: Data) -> Data? {
        var pos = 150

        while pos + 4 <= data.count {
            let entryType = Int16(bitPattern: data.readBE16(at: pos))
            let entryLen = Int(data.readBE16(at: pos + 2))

            if entryType == -1 { break } // Trailer

            if entryType == targetType {
                guard pos + 4 + entryLen <= data.count else { return nil }
                return data.subdata(in: (pos + 4) ..< (pos + 4 + entryLen))
            }

            pos += 4 + entryLen
            if entryLen % 2 == 1 { pos += 1 } // Skip padding byte
        }

        return nil
    }
}
