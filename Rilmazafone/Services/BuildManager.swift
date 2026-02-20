import AppKit
import Foundation
import Observation

// MARK: - Validation

nonisolated enum ValidationError: Error, LocalizedError {
    case missingSourceFile(String)
    case volumeNameEmpty
    case volumeNameTooLong(Int)
    case duplicateLabels([String])

    var errorDescription: String? {
        switch self {
        case let .missingSourceFile(path):
            "Source file not found: \(path)"
        case .volumeNameEmpty:
            "Volume name cannot be empty."
        case let .volumeNameTooLong(count):
            "Volume name is \(count) characters (maximum 27)."
        case let .duplicateLabels(labels):
            "Duplicate item names: \(labels.joined(separator: ", "))"
        }
    }
}

// MARK: - Build Manager

@Observable
final class BuildManager {
    // MARK: - Build State

    enum BuildState: Equatable {
        case idle
        case building(BuildProgress)
        case completed(URL)
        case failed(String)
    }

    struct BuildProgress: Equatable {
        var currentStep: String
        var stepIndex: Int
        var totalSteps: Int

        var fraction: Double {
            guard totalSteps > 0 else { return 0 }
            return Double(stepIndex - 1) / Double(totalSteps)
        }
    }

    private(set) var state: BuildState = .idle

    @ObservationIgnored private var buildTask: Task<Void, Never>?

    var isBuilding: Bool {
        if case .building = state { return true }
        return false
    }

    var isShowingSheet: Bool {
        state != .idle
    }

    // MARK: - Build

    func build(
        configuration: DMGConfiguration,
        assetsDirectory: URL,
        outputURL: URL
    ) {
        buildTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await performBuild(
                    configuration: configuration,
                    assetsDirectory: assetsDirectory,
                    outputURL: outputURL
                )
            } catch is CancellationError {
                await MainActor.run { self.state = .idle }
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
            }

            try? FileManager.default.removeItem(at: assetsDirectory)
        }
    }

    func reportError(_ message: String) {
        state = .failed(message)
    }

    func reset() {
        buildTask?.cancel()
        buildTask = nil
        state = .idle
    }

    // MARK: - Build Pipeline

    private nonisolated func performBuild(
        configuration: DMGConfiguration,
        assetsDirectory: URL,
        outputURL: URL
    ) async throws {
        let totalSteps = 7

        // Step 1: Estimate disk image size
        await updateProgress("Calculating size\u{2026}", step: 1, total: totalSteps)
        let sizeEstimate = try estimateSize(for: configuration)
        try Task.checkCancellation()

        // Step 2: Create writable DMG
        await updateProgress("Creating disk image\u{2026}", step: 2, total: totalSteps)
        let tempDMG = try await DMGBuilder.createWritableImage(
            volumeName: configuration.volumeName,
            size: sizeEstimate,
            filesystem: configuration.filesystem
        )
        try Task.checkCancellation()

        // Step 3: Mount
        await updateProgress("Mounting volume\u{2026}", step: 3, total: totalSteps)
        let mountPoint = try await DMGBuilder.attach(tempDMG)
        var didDetach = false
        defer {
            if !didDetach {
                Task { try? await DMGBuilder.detach(mountPoint) }
            }
        }
        try Task.checkCancellation()

        // Step 4: Copy content
        await updateProgress("Copying files\u{2026}", step: 4, total: totalSteps)
        let validItems = configuration.items.filter { item in
            if item.kind == .applicationsSymlink { return true }
            if item.linkType == .symlink, let target = item.sourcePath, !target.isEmpty { return true }
            if let path = item.sourcePath, FileManager.default.fileExists(atPath: path) { return true }
            return false
        }
        try await DMGBuilder.copyItems(validItems, to: mountPoint)
        try Task.checkCancellation()

        // Step 5: Set up background and .DS_Store
        await updateProgress("Configuring layout\u{2026}", step: 5, total: totalSteps)
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
        await updateProgress("Setting volume icon\u{2026}", step: 6, total: totalSteps)
        let volumeIconData = try await applyVolumeIcon(
            configuration: configuration,
            assetsDirectory: assetsDirectory,
            mountPoint: mountPoint
        )
        try Task.checkCancellation()

        if configuration.filesystem == .hfsPlus {
            try? await DMGBuilder.bless(folder: mountPoint)
        }

        // Step 7: Detach, convert, optionally sign
        await updateProgress("Compressing\u{2026}", step: 7, total: totalSteps)
        try await DMGBuilder.detach(mountPoint)
        didDetach = true
        try await DMGBuilder.convert(
            source: tempDMG,
            destination: outputURL,
            format: configuration.dmgFormat
        )

        try? FileManager.default.removeItem(at: tempDMG)

        if configuration.codeSign.enabled {
            try await DMGBuilder.codeSign(
                dmgPath: outputURL,
                identity: configuration.codeSign.identity
            )
        }

        if let iconData = volumeIconData, let icon = NSImage(data: iconData) {
            await MainActor.run {
                _ = NSWorkspace.shared.setIcon(icon, forFile: outputURL.path, options: [])
            }
        }

        await MainActor.run { self.state = .completed(outputURL) }
    }

    // MARK: - Composite Background

    /// Renders and copies the composite background image to the mounted volume.
    /// Returns the alias and bookmark data for embedding in the .DS_Store.
    private nonisolated func buildCompositeBackground(
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

        guard let compositeImage = CompositeRenderer.renderBackground(
            configuration: configuration, assetsDirectory: assetsDirectory
        ),
            let tiffData = compositeImage.tiffRepresentation,
            let pngData = NSBitmapImageRep(data: tiffData)?.representation(using: .png, properties: [:])
        else { return (nil, nil) }

        let bgImageName = "background.png"
        try pngData.write(to: assetsDirectory.appending(path: bgImageName))
        try await DMGBuilder.copyBackground(named: bgImageName, from: assetsDirectory, to: mountPoint)

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
    /// Returns the icon data for setting on the final .dmg file.
    private nonisolated func applyVolumeIcon(
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

    private func updateProgress(_ step: String, step index: Int, total: Int) {
        state = .building(BuildProgress(
            currentStep: step,
            stepIndex: index,
            totalSteps: total
        ))
    }

    // MARK: - Size Estimation

    private nonisolated func estimateSize(for configuration: DMGConfiguration) throws -> String {
        var totalBytes: UInt64 = 32 * 1_024 * 1_024 // 32 MB base overhead

        for item in configuration.items {
            guard item.kind != .applicationsSymlink else { continue }
            guard let path = item.sourcePath else { continue }

            let url = URL(fileURLWithPath: path)
            if let size = try? FileManager.default.allocatedSizeOfDirectory(at: url) {
                totalBytes += size
            }
        }

        // 1.5x headroom for block alignment + filesystem metadata
        totalBytes = UInt64(Double(totalBytes) * 1.5)

        // APFS requires a larger minimum container size
        let minimumBytes: UInt64 = configuration.filesystem == .apfs
            ? 128 * 1_024 * 1_024 // 128 MB minimum for APFS
            : 32 * 1_024 * 1_024 // 32 MB minimum for HFS+
        totalBytes = max(totalBytes, minimumBytes)

        let megabytes = Int(totalBytes / (1_024 * 1_024))
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
