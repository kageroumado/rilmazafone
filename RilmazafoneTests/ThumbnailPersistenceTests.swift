import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Rilmazafone

@Suite("Thumbnail persistence")
struct ThumbnailPersistenceTests {
    /// A tiny valid PNG (1×1, opaque) to stand in for a rendered thumbnail.
    private static let pngFixture = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==")!

    @Test
    @MainActor
    func `save writes thumbnail png into the package`() throws {
        let doc = RilmazafoneDocument()
        doc.thumbnailPNG = Self.pngFixture

        let snapshot = try doc.snapshot(contentType: .rilmazafoneDocument)
        let wrapper = try RilmazafoneDocument.makeFileWrapper(snapshot: snapshot)

        let thumbnail = wrapper.fileWrappers?["thumbnail.png"]
        #expect(thumbnail?.regularFileContents == Self.pngFixture)
    }

    @Test
    @MainActor
    func `save omits thumbnail when none was rendered`() throws {
        let doc = RilmazafoneDocument()

        let snapshot = try doc.snapshot(contentType: .rilmazafoneDocument)
        let wrapper = try RilmazafoneDocument.makeFileWrapper(snapshot: snapshot)

        #expect(wrapper.fileWrappers?["thumbnail.png"] == nil)
    }
}
