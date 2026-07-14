import Foundation
import Testing
@testable import Rilmazafone

@Suite("AliasRecordReader")
struct AliasRecordReaderTests {
    // MARK: - Round-Trip vs AliasRecordBuilder

    @Test("Round-trips a simple record from our builder")
    func roundTripSimple() throws {
        let data = try buildAlias(volumeName: "TestVol", imageName: "background.png")

        #expect(AliasRecordReader.volumeRelativePath(from: data) == ".background/background.png")
    }

    @Test("Round-trips volume and image names containing spaces")
    func roundTripSpaces() throws {
        let data = try buildAlias(volumeName: "My App 1.0", imageName: "bg image.tiff")

        #expect(AliasRecordReader.volumeRelativePath(from: data) == ".background/bg image.tiff")
    }

    @Test("Round-trips a 27-byte UTF-8 volume name")
    func roundTripMaxUTF8VolumeName() throws {
        let volumeName = "日本語ボリューム名"
        #expect(volumeName.utf8.count == 27)

        let data = try buildAlias(volumeName: volumeName, imageName: "background.png")

        #expect(AliasRecordReader.volumeRelativePath(from: data) == ".background/background.png")
    }

    @Test("Round-trips a Unicode image name")
    func roundTripUnicodeImageName() throws {
        let data = try buildAlias(volumeName: "TestVol", imageName: "背景 image.png")

        #expect(AliasRecordReader.volumeRelativePath(from: data) == ".background/背景 image.png")
    }

    // MARK: - Signal Priority Fallbacks

    @Test("Falls back to the Carbon path when the POSIX path record is absent")
    func carbonPathFallback() throws {
        let data = try buildAlias(volumeName: "TestVol", imageName: "bg.png")
        let stripped = removingExtras(withTags: [18, 19], from: data)

        #expect(AliasRecordReader.volumeRelativePath(from: stripped) == ".background/bg.png")
    }

    @Test("Falls back to Unicode file name plus parent folder name")
    func unicodeNameFallback() throws {
        let data = try buildAlias(volumeName: "TestVol", imageName: "bg.png")
        let stripped = removingExtras(withTags: [2, 18, 19], from: data)

        #expect(AliasRecordReader.volumeRelativePath(from: stripped) == ".background/bg.png")
    }

    @Test("Falls back to the Pascal file name when all extras are absent")
    func pascalNameFallback() throws {
        let data = try buildAlias(volumeName: "TestVol", imageName: "bg.png")
        let stripped = removingExtras(withTags: [0, 1, 2, 14, 15, 18, 19], from: data)

        #expect(AliasRecordReader.volumeRelativePath(from: stripped) == ".background/bg.png")
    }

    @Test("Decodes a MacRoman Pascal file name")
    func macRomanFileName() throws {
        let data = try buildAlias(volumeName: "TestVol", imageName: "cafe.png")
        var stripped = removingExtras(withTags: [0, 1, 2, 14, 15, 18, 19], from: data)
        // Patch the Pascal file name at offset 50 to MacRoman "café.png"
        // (0x8E = é), which is invalid UTF-8.
        let macRoman: [UInt8] = [0x63, 0x61, 0x66, 0x8E, 0x2E, 0x70, 0x6E, 0x67]
        stripped[50] = UInt8(macRoman.count)
        stripped.replaceSubrange(51 ..< 51 + macRoman.count, with: macRoman)

        #expect(AliasRecordReader.volumeRelativePath(from: stripped) == ".background/café.png")
    }

    // MARK: - Third-Party DMG Fixtures

    @Test("Resolves the background path from a DMG Canvas alias (SigmaOS)")
    func dmgCanvasFixture() throws {
        let data = try fixture("alias-sigmaos")

        #expect(AliasRecordReader.volumeRelativePath(from: data) == ".background/dmgcanvas_bg.tiff")
    }

    @Test("Resolves the background path from a create-dmg alias (ImHex)")
    func createDMGFixture() throws {
        let data = try fixture("alias-imhex")

        #expect(AliasRecordReader.volumeRelativePath(from: data) == ".background/dmg-background.tiff")
    }

    @Test("Resolves the background path from an appdmg alias (Refrax)")
    func appdmgFixture() throws {
        let data = try fixture("alias-refrax")

        #expect(AliasRecordReader.volumeRelativePath(from: data) == ".background/background.png")
    }

    @Test("Normalizes the DMG Canvas Carbon path form (/:Volumes:Name:…)")
    func dmgCanvasCarbonPathForm() throws {
        // SigmaOS's tag 2 reads "/:Volumes:SigmaOS:.background:dmgcanvas_bg.tiff".
        // Stripping the POSIX records forces the Carbon path branch.
        let data = try fixture("alias-sigmaos")
        let stripped = removingExtras(withTags: [18, 19], from: data)

        #expect(AliasRecordReader.volumeRelativePath(from: stripped) == ".background/dmgcanvas_bg.tiff")
    }

    // MARK: - Malformed Input

    @Test("Empty data returns nil")
    func emptyData() {
        #expect(AliasRecordReader.volumeRelativePath(from: Data()) == nil)
    }

    @Test("Data shorter than the header returns nil")
    func truncatedHeader() throws {
        let data = try buildAlias(volumeName: "TestVol", imageName: "bg.png")

        for length in [1, 40, 149] {
            #expect(AliasRecordReader.volumeRelativePath(from: data.prefix(length)) == nil)
        }
    }

    @Test("Unsupported version returns nil")
    func wrongVersion() throws {
        var data = try buildAlias(volumeName: "TestVol", imageName: "bg.png")
        data[6] = 0
        data[7] = 3

        #expect(AliasRecordReader.volumeRelativePath(from: data) == nil)
    }

    @Test("Random bytes return nil without crashing")
    func randomBytes() {
        var generator = SplitMix64(seed: 0x5EED)
        for length in [150, 200, 336, 512, 4096] {
            var data = Data((0 ..< length).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            data[6] = 0x09
            data[7] = 0x99

            #expect(AliasRecordReader.volumeRelativePath(from: data) == nil)
        }
    }

    @Test("Record truncated mid-extras still recovers the file name")
    func truncatedExtras() throws {
        let data = try buildAlias(volumeName: "TestVol", imageName: "background.png")

        for length in [150, 160] {
            let truncated = data.prefix(length)
            #expect(AliasRecordReader.volumeRelativePath(from: truncated) == ".background/background.png")
        }
    }

    // MARK: - Directory-Scan Fallback

    @Test("firstImage returns the lexicographically first image")
    func firstImageSorted() throws {
        let root = try makeVolume(backgroundDir: ".background", files: ["zebra.png", "alpha.tiff", "notes.txt"])
        defer { try? FileManager.default.removeItem(at: root) }

        let found = AliasRecordReader.firstImage(inBackgroundDirectoryOf: root)

        #expect(found?.lastPathComponent == "alpha.tiff")
    }

    @Test("firstImage supports the .bg directory convention")
    func firstImageDotBG() throws {
        let root = try makeVolume(backgroundDir: ".bg", files: ["back.jpeg"])
        defer { try? FileManager.default.removeItem(at: root) }

        let found = AliasRecordReader.firstImage(inBackgroundDirectoryOf: root)

        #expect(found?.lastPathComponent == "back.jpeg")
    }

    @Test("firstImage ignores non-image files")
    func firstImageNonImages() throws {
        let root = try makeVolume(backgroundDir: ".background", files: ["readme.txt", "data.json"])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(AliasRecordReader.firstImage(inBackgroundDirectoryOf: root) == nil)
    }

    @Test("firstImage returns nil for an empty background directory")
    func firstImageEmptyDirectory() throws {
        let root = try makeVolume(backgroundDir: ".background", files: [])
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(AliasRecordReader.firstImage(inBackgroundDirectoryOf: root) == nil)
    }

    @Test("firstImage returns nil when no background directory exists")
    func firstImageMissingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rilmazafone-reader-missing-\(UUID().uuidString)")

        #expect(AliasRecordReader.firstImage(inBackgroundDirectoryOf: root) == nil)
    }

    // MARK: - Helpers

    /// Builds a real alias record via AliasRecordBuilder against a temporary
    /// directory structure that mimics a mounted volume.
    private func buildAlias(volumeName: String, imageName: String) throws -> Data {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "rilmazafone-reader-test-\(UUID().uuidString)")
        let backgroundDir = tmpDir.appending(path: ".background")
        let imageFile = backgroundDir.appending(path: imageName)

        try FileManager.default.createDirectory(at: backgroundDir, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageFile)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        return try AliasRecordBuilder.createBackgroundAlias(
            imageName: imageName,
            volumeName: volumeName,
            mountPoint: tmpDir
        )
    }

    /// Rebuilds an alias record without the extended info entries whose tags
    /// appear in `tags`, updating the header size field.
    private func removingExtras(withTags tags: Set<Int16>, from data: Data) -> Data {
        var result = data.prefix(150)
        var pos = 150

        while pos + 4 <= data.count {
            let tag = Int16(bitPattern: data.readBE16(at: pos))
            let length = Int(data.readBE16(at: pos + 2))
            if tag == -1 { break }
            let entryEnd = pos + 4 + length + (length % 2)
            guard entryEnd <= data.count else { break }
            if !tags.contains(tag) {
                result.append(data[pos ..< entryEnd])
            }
            pos = entryEnd
        }

        result.appendBigEndianUInt16(UInt16(bitPattern: -1))
        result.appendBigEndianUInt16(0)

        var rebuilt = Data(result)
        rebuilt[4] = UInt8((rebuilt.count >> 8) & 0xFF)
        rebuilt[5] = UInt8(rebuilt.count & 0xFF)
        return rebuilt
    }

    /// Loads a raw alias fixture extracted from a real third-party DMG.
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle(for: ReaderBundleMarker.self).url(forResource: name, withExtension: "bin"),
            "Missing test fixture \(name).bin"
        )
        return try Data(contentsOf: url)
    }

    /// Creates a temporary fake volume root with a background directory.
    private func makeVolume(backgroundDir: String, files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "rilmazafone-reader-vol-\(UUID().uuidString)")
        let dir = root.appending(path: backgroundDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in files {
            try Data([0x00]).write(to: dir.appending(path: name))
        }
        return root
    }
}

/// Marker class for Bundle(for:) in the test target.
private class ReaderBundleMarker {}

/// Deterministic RNG for the garbage-input test.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
