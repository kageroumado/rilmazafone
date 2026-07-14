import AppKit
import Foundation
import os

/// The shared, off-main DMG build pipeline driven by both the GUI (`BuildManager`)
/// and the headless CLI (`CLIBuildRunner`).
///
/// Runs the full seven-step sequence — size estimation, writable image creation,
/// attach/detach, item copy, composite background + `.DS_Store`, volume icon,
/// best-effort bless, convert, and optional code signing — reporting progress
/// through a `@Sendable` callback so each front end can surface it in its own way.
///
/// The caller owns `assetsDirectory`: it is created and cleaned up outside the
/// pipeline, which only reads bundled assets from it and writes the rendered
/// background image into it.
nonisolated enum DMGBuildPipeline {
    /// Progress emitted immediately before each build step begins.
    struct Progress: Sendable {
        /// Human-readable description of the step about to run (e.g. "Copying files…").
        let step: String
        /// 1-based index of the current step.
        let stepIndex: Int
        /// Total number of steps in the build.
        let totalSteps: Int

        /// Fraction of the build completed before this step begins, in `0...1`.
        var fraction: Double {
            guard totalSteps > 0 else { return 0 }
            return Double(stepIndex - 1) / Double(totalSteps)
        }
    }

    /// Unified-logging destination for build diagnostics that must not surface to the user.
    private static let logger = Logger(subsystem: "glass.kagerou.rilmazafone", category: "build")

    private enum Constants {
        static let totalSteps = 7
        static let baseOverheadBytes: UInt64 = 32 * 1_024 * 1_024
        static let headroomFactor = 1.5
        static let apfsMinimumBytes: UInt64 = 128 * 1_024 * 1_024
        static let hfsMinimumBytes: UInt64 = 32 * 1_024 * 1_024
        static let bytesPerMegabyte: UInt64 = 1_024 * 1_024
        static let backgroundImageName = "background.tiff"
    }

    // MARK: - Build

    /// Builds the DMG described by `configuration`, writing the finished image to `outputURL`.
    ///
    /// Throws on any failure — including `CancellationError` if the surrounding task is
    /// cancelled between steps.
    ///
    /// All subprocess I/O (`hdiutil` create/attach/convert and `codesign`) operates on
    /// paths inside `FileManager.default.temporaryDirectory` — the app container when
    /// sandboxed, where child processes have static-sandbox access. The finished image is
    /// then relocated to the user-selected `outputURL` with a single in-process
    /// `FileManager` move, which carries the Powerbox grant the save panel established.
    ///
    /// Every temporary artifact (writable image, mount-point directory, staged converted
    /// image) is removed on success *and* on every failure or cancellation path via
    /// `defer`, so a cancelled build leaves no stray mounts or temp files behind.
    static func build(
        configuration: DMGConfiguration,
        assetsDirectory: URL,
        outputURL: URL,
        progress: @Sendable (Progress) async -> Void
    ) async throws {
        let total = Constants.totalSteps
        let fileManager = FileManager.default

        // Step 1: Estimate disk image size
        await progress(Progress(step: "Calculating size\u{2026}", stepIndex: 1, totalSteps: total))
        let sizeEstimate = try estimateSize(for: configuration)
        try Task.checkCancellation()

        // Step 2: Create writable DMG
        await progress(Progress(step: "Creating disk image\u{2026}", stepIndex: 2, totalSteps: total))
        let tempDMG = try await DMGBuilder.createWritableImage(
            volumeName: configuration.volumeName,
            size: sizeEstimate,
            filesystem: configuration.filesystem
        )
        defer { try? fileManager.removeItem(at: tempDMG) }
        try Task.checkCancellation()

        // Step 3: Mount
        await progress(Progress(step: "Mounting volume\u{2026}", stepIndex: 3, totalSteps: total))
        let mountPoint = try await DMGBuilder.attach(tempDMG)
        // The empty mount-point directory `attach` created is removed on every exit path;
        // it is empty by the time this runs because the volume is always detached below.
        defer { try? fileManager.removeItem(at: mountPoint) }
        try Task.checkCancellation()

        // While the volume is mounted, any failure or cancellation must still unmount it,
        // so the mounted-phase work is wrapped in a do/catch that awaits `detach` before
        // rethrowing — reliable even in a short-lived CLI process, unlike a detached Task.
        let volumeIconData: Data?
        do {
            // Step 4: Copy content
            await progress(Progress(step: "Copying files\u{2026}", stepIndex: 4, totalSteps: total))
            let validItems = configuration.items.filter { item in
                if item.kind == .applicationsSymlink { return true }
                if item.linkType == .symlink, let target = item.sourcePath, !target.isEmpty { return true }
                if let path = item.sourcePath, FileManager.default.fileExists(atPath: path) { return true }
                return false
            }
            try DMGBuilder.copyItems(validItems, to: mountPoint)
            try Task.checkCancellation()

            // Step 5: Set up background and .DS_Store
            await progress(Progress(step: "Configuring layout\u{2026}", stepIndex: 5, totalSteps: total))
            let (backgroundAlias, backgroundBookmark) = try await buildCompositeBackground(
                configuration: configuration,
                assetsDirectory: assetsDirectory,
                mountPoint: mountPoint
            )

            var dsStoreConfig = configuration
            if backgroundAlias != nil {
                dsStoreConfig.background.type = .image
            }

            let dsStoreData = try DSStoreWriter.write(
                configuration: dsStoreConfig,
                backgroundAlias: backgroundAlias,
                backgroundBookmark: backgroundBookmark
            )
            try dsStoreData.write(to: mountPoint.appending(path: ".DS_Store"))
            try Task.checkCancellation()

            // Step 6: Volume icon
            await progress(Progress(step: "Setting volume icon\u{2026}", stepIndex: 6, totalSteps: total))
            volumeIconData = try await applyVolumeIcon(
                configuration: configuration,
                assetsDirectory: assetsDirectory,
                mountPoint: mountPoint
            )
            try Task.checkCancellation()

            await blessIfApplicable(configuration: configuration, mountPoint: mountPoint)

            // Step 7: Unmount before converting.
            await progress(Progress(step: "Compressing\u{2026}", stepIndex: 7, totalSteps: total))
            try await DMGBuilder.detach(mountPoint)
        } catch {
            try? await DMGBuilder.detach(mountPoint)
            throw error
        }

        // Convert and sign a staged image inside temporaryDirectory; the user path is
        // only touched by the final in-process move so no child process needs a Powerbox
        // grant it cannot inherit.
        let stagedDMG = fileManager.temporaryDirectory
            .appending(path: "rilmazafone-build-\(UUID().uuidString).dmg")
        defer { try? fileManager.removeItem(at: stagedDMG) }

        try await DMGBuilder.convert(
            source: tempDMG,
            destination: stagedDMG,
            format: configuration.dmgFormat
        )

        if configuration.codeSign.enabled {
            try await DMGBuilder.codeSign(
                dmgPath: stagedDMG,
                identity: configuration.codeSign.identity
            )
        }

        // Relocate the finished image to the user-selected destination. The save panel
        // already confirmed any overwrite, so replace an existing file, then move.
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        try fileManager.moveItem(at: stagedDMG, to: outputURL)

        if let iconData = volumeIconData, let icon = NSImage(data: iconData) {
            NSWorkspace.shared.setIcon(icon, forFile: outputURL.path, options: [])
        }
    }

    // MARK: - Bless

    /// Blesses the mounted volume so Finder opens it to the right folder — a cosmetic,
    /// HFS+-only nicety. `bless` is unavailable on APFS and likely hostile under sandbox,
    /// so it is best-effort: any failure is logged once (visible in the build log and
    /// Console) and never surfaced to the user, and the build proceeds regardless.
    ///
    /// This is the single call site so Phase 1 can gate the whole step behind
    /// `#if APPSTORE` without touching the build sequence.
    private static func blessIfApplicable(
        configuration: DMGConfiguration,
        mountPoint: URL
    ) async {
        guard configuration.filesystem == .hfsPlus else { return }
        do {
            try await DMGBuilder.bless(folder: mountPoint)
        } catch {
            logger.warning("bless failed (cosmetic, ignored): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Composite Background

    /// Renders and copies the composite background image to the mounted volume.
    /// Returns the alias and bookmark data for embedding in the `.DS_Store`.
    private static func buildCompositeBackground(
        configuration: DMGConfiguration,
        assetsDirectory: URL,
        mountPoint: URL
    ) async throws -> (alias: Data?, bookmark: Data?) {
        let needsComposite = (configuration.background.type == .image && !configuration.background.layers.isEmpty)
            || !configuration.textLayers.isEmpty
            || !configuration.sfSymbolLayers.isEmpty
            || configuration.items.contains(where: { $0.background != nil })
            || (configuration.background.type == .gradient && configuration.background.gradient != nil)

        guard needsComposite else { return (nil, nil) }

        guard let tiffData = CompositeRenderer.renderBackgroundTIFF(
            configuration: configuration, assetsDirectory: assetsDirectory
        ) else { return (nil, nil) }

        let bgImageName = Constants.backgroundImageName
        try tiffData.write(to: assetsDirectory.appending(path: bgImageName))
        try DMGBuilder.copyBackground(named: bgImageName, from: assetsDirectory, to: mountPoint)

        let alias = try AliasRecordBuilder.createBackgroundAlias(
            imageName: bgImageName,
            volumeName: configuration.volumeName,
            mountPoint: mountPoint
        )

        let bgFileOnVolume = mountPoint.appending(path: ".background").appending(path: bgImageName)
        let bookmark = try? bgFileOnVolume.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )

        return (alias, bookmark)
    }

    // MARK: - Volume Icon

    /// Resolves and applies the volume icon to the mounted DMG volume.
    /// Returns the icon data for setting on the final `.dmg` file.
    private static func applyVolumeIcon(
        configuration: DMGConfiguration,
        assetsDirectory: URL,
        mountPoint: URL
    ) async throws -> Data? {
        switch configuration.volumeIcon.type {
        case .composed:
            guard let app = configuration.items.first(where: { $0.kind == .app }),
                  let appPath = app.sourcePath,
                  let iconPath = IconComposer.resolveAppIconURL(appPath: appPath),
                  FileManager.default.fileExists(atPath: iconPath.path)
            else { return nil }
            do {
                let composedICNS = try await IconComposer.compose(appIconURL: iconPath)
                try await DMGBuilder.setVolumeIcon(icnsData: composedICNS, mountPoint: mountPoint)
                return composedICNS
            } catch {
                return nil // Icon composition is optional
            }

        case .custom:
            guard let iconName = configuration.volumeIcon.sourceIconName else { return nil }
            let iconURL = assetsDirectory.appending(path: iconName)
            guard FileManager.default.fileExists(atPath: iconURL.path) else { return nil }
            let iconData = try Data(contentsOf: iconURL)
            try await DMGBuilder.setVolumeIcon(icnsData: iconData, mountPoint: mountPoint)
            return iconData

        case .none:
            return nil
        }
    }

    // MARK: - Size Estimation

    /// Estimates the writable image size (as an `hdiutil` size string, e.g. `"128m"`)
    /// from the total allocated size of the configuration's source items.
    static func estimateSize(for configuration: DMGConfiguration) throws -> String {
        var totalBytes = Constants.baseOverheadBytes

        for item in configuration.items {
            guard item.kind != .applicationsSymlink else { continue }
            guard let path = item.sourcePath else { continue }

            let url = URL(fileURLWithPath: path)
            if let size = try? FileManager.default.allocatedSizeOfDirectory(at: url) {
                totalBytes += size
            }
        }

        totalBytes = UInt64(Double(totalBytes) * Constants.headroomFactor)

        let minimumBytes = configuration.filesystem == .apfs
            ? Constants.apfsMinimumBytes
            : Constants.hfsMinimumBytes
        totalBytes = max(totalBytes, minimumBytes)

        let megabytes = Int(totalBytes / Constants.bytesPerMegabyte)
        return "\(megabytes)m"
    }
}

// MARK: - FileManager Size Helper

private extension FileManager {
    nonisolated func allocatedSizeOfDirectory(at url: URL) throws -> UInt64 {
        var isDir: ObjCBool = false
        guard fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        if !isDir.boolValue {
            let attrs = try attributesOfItem(atPath: url.path)
            return attrs[.size] as? UInt64 ?? 0
        }

        var size: UInt64 = 0
        let enumerator = enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if resourceValues.isRegularFile == true {
                size += UInt64(resourceValues.fileSize ?? 0)
            }
        }

        return size
    }
}
