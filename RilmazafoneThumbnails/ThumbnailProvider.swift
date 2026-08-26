import AppKit
import QuickLookThumbnailing

/// Draws Finder thumbnails for Rilmazafone's package documents from the
/// `thumbnail.png` the canvas persists on save: a `.dmgtemplate` carries its
/// own, a `.releaseplan` shows its embedded design's. Documents without one
/// (saved by an older build, or a plan referencing an external design) fall
/// back to the generic document icon.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        guard let thumbnailURL = Self.thumbnailURL(for: request.fileURL),
              let image = NSImage(contentsOf: thumbnailURL),
              image.size.width > 0, image.size.height > 0
        else {
            handler(nil, nil)
            return
        }

        let scale = min(
            request.maximumSize.width / image.size.width,
            request.maximumSize.height / image.size.height
        )
        let contextSize = CGSize(
            width: max(1, (image.size.width * scale).rounded(.down)),
            height: max(1, (image.size.height * scale).rounded(.down))
        )

        handler(QLThumbnailReply(contextSize: contextSize) {
            image.draw(in: CGRect(origin: .zero, size: contextSize))
            return true
        }, nil)
    }

    private static func thumbnailURL(for fileURL: URL) -> URL? {
        switch fileURL.pathExtension.lowercased() {
        case "dmgtemplate":
            fileURL.appendingPathComponent("thumbnail.png")
        case "releaseplan":
            fileURL.appendingPathComponent("Design.dmgtemplate/thumbnail.png")
        default:
            nil
        }
    }
}
