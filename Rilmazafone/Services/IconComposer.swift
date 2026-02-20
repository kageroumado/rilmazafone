import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Composes volume icons by applying a perspective transform to an app icon
/// and overlaying it onto a base disk icon.
///
/// The pipeline processes each `.icns` image variant independently to preserve
/// resolution-specific detail, then reassembles the results into a new `.icns`.
nonisolated enum IconComposer {
    // MARK: - Errors

    nonisolated enum ComposerError: Error, LocalizedError {
        case loadFailed(URL)
        case noDiskIconResource
        case resizeFailed
        case compositeFailed
        case icnsParseFailed
        case noUsableVariants

        var errorDescription: String? {
            switch self {
            case let .loadFailed(url):
                "Could not load image from '\(url.path)'."
            case .noDiskIconResource:
                "Disk icon resource not found (checked system and bundle)."
            case .resizeFailed:
                "Image resize failed."
            case .compositeFailed:
                "Image compositing failed."
            case .icnsParseFailed:
                "Could not parse .icns file."
            case .noUsableVariants:
                "No usable image variants found in .icns file."
            }
        }
    }

    // MARK: - Layout Constants

    /// Layout constants for composing the app icon onto the disk volume icon.
    private enum Layout {
        /// Width resize factor to fit app icon inside disk icon.
        static let widthResizeFactor = 1.8

        /// Height resize factor to fit app icon inside disk icon.
        static let heightResizeFactor = 1.8

        /// Vertical offset factor to position app icon on the disk face.
        static let verticalOffsetFactor = 0.04
    }

    // MARK: - ICNS Format

    /// A single image entry within an `.icns` file.
    private struct ICNSEntry {
        let type: String // 4-char code (e.g., "ic10", "ic09")
        let data: Data
    }

    /// The magic bytes at the start of every `.icns` file.
    private static let icnsMagic: [UInt8] = [0x69, 0x63, 0x6E, 0x73] // "icns"

    /// Known icon types that contain actual image data (PNG or JPEG2000),
    /// mapped to their pixel dimensions.
    private static let imageTypePixelSizes: [String: Int] = [
        "ic04": 16, // 16x16
        "ic05": 32, // 32x32
        "ic07": 128, // 128x128
        "ic08": 256, // 256x256
        "ic09": 512, // 512x512
        "ic10": 1_024, // 1024x1024 (512x512@2x)
        "ic11": 64, // 32x32@2x
        "ic12": 128, // 64x64@2x (128px)
        "ic13": 512, // 256x256@2x (512px)
        "ic14": 1_024, // 512x512@2x (1024px)
    ]

    // MARK: - Public API

    /// The bundled disk image volume icon used as the base for composition.
    static let diskImageVolumeIcon: NSImage = {
        guard let image = Bundle.main.image(forResource: "DiskImageVolume") else {
            preconditionFailure("DiskImageVolume.png missing from app resources — ensure it is included in the bundle.")
        }
        return image
    }()

    /// Resolves the path to an app bundle's `.icns` file, checking
    /// `CFBundleIconFile`, `CFBundleIconName`, and falling back to any `.icns` in Resources.
    static func resolveAppIconURL(appPath: String) -> URL? {
        guard let appBundle = Bundle(path: appPath),
              let resourceURL = appBundle.resourceURL else { return nil }

        let info = appBundle.infoDictionary

        // CFBundleIconFile (explicit .icns path)
        if let iconFile = info?["CFBundleIconFile"] as? String {
            var path = resourceURL.appending(path: iconFile)
            if path.pathExtension.isEmpty {
                path = path.appendingPathExtension("icns")
            }
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }

        // CFBundleIconName (asset catalog — Xcode generates a matching .icns)
        if let iconName = info?["CFBundleIconName"] as? String {
            let path = resourceURL.appending(path: iconName).appendingPathExtension("icns")
            if FileManager.default.fileExists(atPath: path.path) {
                return path
            }
        }

        // Fallback: any .icns in Resources
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: resourceURL,
            includingPropertiesForKeys: nil
        ) {
            return contents.first { $0.pathExtension == "icns" }
        }

        return nil
    }

    /// Composes a volume icon from an app's `.icns` file and the bundled disk icon.
    ///
    /// Pipeline per variant:
    /// 1. Extract image from `.icns` entry
    /// 2. Render the base disk icon at the matching pixel size
    /// 3. Resize the app icon to fit inside the disk icon
    /// 4. Overlay onto the disk icon with vertical offset
    ///
    /// - Parameter appIconURL: Path to the app's `.icns` file.
    /// - Returns: Data containing the composed `.icns` file.
    static func compose(appIconURL: URL) async throws -> Data {
        let diskIcon = diskImageVolumeIcon
        let appEntries = try parseICNS(at: appIconURL)

        var composedEntries: [ICNSEntry] = []

        for appEntry in appEntries {
            guard let pixelSize = imageTypePixelSizes[appEntry.type] else {
                composedEntries.append(appEntry)
                continue
            }

            guard let appImage = cgImage(from: appEntry.data),
                  let diskImage = renderIcon(diskIcon, atPixelSize: pixelSize)
            else {
                composedEntries.append(appEntry)
                continue
            }

            do {
                let composed = try composeVariant(
                    appIcon: appImage,
                    diskIcon: diskImage
                )

                let pngData = try pngData(from: composed)
                composedEntries.append(ICNSEntry(type: appEntry.type, data: pngData))
            } catch {
                composedEntries.append(appEntry)
            }
        }

        guard !composedEntries.isEmpty else {
            throw ComposerError.noUsableVariants
        }

        return assembleICNS(entries: composedEntries)
    }

    /// Overlays the app icon onto a base disk icon.
    static func overlay(
        appIcon: CGImage,
        onto diskIcon: CGImage
    ) throws -> CGImage {
        let diskSize = CGSize(
            width: CGFloat(diskIcon.width),
            height: CGFloat(diskIcon.height)
        )

        guard let context = rgbaContext(size: diskSize) else {
            throw ComposerError.compositeFailed
        }

        // Draw the disk icon as the base
        context.draw(diskIcon, in: CGRect(origin: .zero, size: diskSize))

        // Calculate centered position with vertical offset
        let verticalOffset = Double(diskIcon.height) * Layout.verticalOffsetFactor
        let x = Double(diskIcon.width - appIcon.width) / 2
        let y = Double(diskIcon.height - appIcon.height) / 2 + verticalOffset

        // Draw the app icon overlay
        context.draw(
            appIcon,
            in: CGRect(
                origin: CGPoint(x: x, y: y),
                size: CGSize(width: appIcon.width, height: appIcon.height)
            )
        )

        guard let result = context.makeImage() else {
            throw ComposerError.compositeFailed
        }

        return result
    }

    // MARK: - Private: Composition Pipeline

    private static func composeVariant(
        appIcon: CGImage,
        diskIcon: CGImage
    ) throws -> CGImage {
        // Resize to fit inside the disk icon
        let targetSize = CGSize(
            width: (Double(diskIcon.width) / Layout.widthResizeFactor).rounded(),
            height: (Double(diskIcon.height) / Layout.heightResizeFactor).rounded()
        )

        guard let resized = resize(appIcon, to: targetSize) else {
            throw ComposerError.resizeFailed
        }

        // Overlay onto disk icon
        return try overlay(appIcon: resized, onto: diskIcon)
    }

    // MARK: - Private: ICNS Parsing

    /// Parses an `.icns` file into its component entries.
    private static func parseICNS(at url: URL) throws -> [ICNSEntry] {
        let data = try Data(contentsOf: url)
        guard data.count >= 8 else { throw ComposerError.icnsParseFailed }

        // Verify magic
        let magic = [UInt8](data[0 ..< 4])
        guard magic == icnsMagic else { throw ComposerError.icnsParseFailed }

        let totalSize = data.readBigEndianUInt32(at: 4)
        guard totalSize <= data.count else { throw ComposerError.icnsParseFailed }

        var entries: [ICNSEntry] = []
        var offset = 8

        while offset + 8 <= Int(totalSize) {
            let typeBytes = data[offset ..< offset + 4]
            let typeCode = String(bytes: typeBytes, encoding: .ascii) ?? "????"
            let entrySize = Int(data.readBigEndianUInt32(at: offset + 4))

            guard entrySize >= 8, offset + entrySize <= Int(totalSize) else { break }

            let entryData = data[offset + 8 ..< offset + entrySize]
            entries.append(ICNSEntry(type: typeCode, data: Data(entryData)))

            offset += entrySize
        }

        return entries
    }

    /// Assembles ICNS entries back into an `.icns` file.
    private static func assembleICNS(entries: [ICNSEntry]) -> Data {
        var body = Data()
        for entry in entries {
            // Type code (4 bytes)
            body.appendASCII(entry.type)
            // Entry size (4 bytes): header + data
            body.appendBigEndianUInt32(UInt32(entry.data.count + 8))
            // Data
            body.append(entry.data)
        }

        var file = Data()
        // Magic (4 bytes)
        file.append(contentsOf: icnsMagic)
        // Total file size (4 bytes)
        file.appendBigEndianUInt32(UInt32(body.count + 8))
        // Body
        file.append(body)

        return file
    }

    // MARK: - Private: Image Utilities

    /// Renders an NSImage at the exact pixel dimensions needed for an icns entry.
    private static func renderIcon(_ icon: NSImage, atPixelSize pixels: Int) -> CGImage? {
        let size = NSSize(width: pixels, height: pixels)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        return rep.cgImage
    }

    private static func cgImage(from data: Data) -> CGImage? {
        guard data.count >= 8 else { return nil }

        // Legacy ARGB entries are raw pixel data, not a decodable image format.
        // Check for known image headers (PNG or JPEG2000) before attempting decode.
        let header = [UInt8](data[data.startIndex ..< data.startIndex + 4])
        let isPNG = header[0] == 0x89 && header[1] == 0x50 && header[2] == 0x4E && header[3] == 0x47
        let isJP2 = header[0] == 0x00 && header[1] == 0x00 && header[2] == 0x00 && header[3] == 0x0C
        guard isPNG || isJP2 else { return nil }

        guard let provider = CGDataProvider(data: data as CFData),
              let source = CGImageSourceCreateWithDataProvider(provider, nil)
        else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func pngData(from image: CGImage) throws -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ComposerError.compositeFailed
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ComposerError.compositeFailed
        }

        return mutableData as Data
    }

    private static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard let context = rgbaContext(size: size) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    private static func rgbaContext(size: CGSize) -> CGContext? {
        CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        )
    }
}

// MARK: - Data Reading Helpers

private nonisolated extension Data {
    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        let bytes = self[offset ..< offset + 4]
        var value: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { dest in
            bytes.copyBytes(to: dest)
        }
        return UInt32(bigEndian: value)
    }
}
