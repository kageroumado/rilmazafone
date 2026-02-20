import AppKit
import Foundation

/// Headless DMG build runner for CLI invocation.
///
/// Usage: `Rilmazafone build <template.rilmazafone> -o <output.dmg>`
///
/// Reuses the same pipeline as `BuildManager` (DMGBuilder, CompositeRenderer,
/// IconComposer, DSStoreWriter) but runs sequentially with stderr progress output.
nonisolated enum CLIBuildRunner {
    // MARK: - Entry Points

    static func run(arguments: [String]) -> Int32 {
        if arguments.first == "-h" || arguments.first == "--help" {
            printBuildUsage()
            return 0
        }

        guard let (templatePath, outputPath) = parseBuildArguments(arguments) else {
            printBuildUsage()
            return 1
        }

        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var exitCode: Int32 = 1

        Task { @Sendable in
            exitCode = await performBuild(templatePath: templatePath, outputPath: outputPath)
            semaphore.signal()
        }

        semaphore.wait()
        return exitCode
    }

    static func runInit(arguments: [String]) -> Int32 {
        if arguments.first == "-h" || arguments.first == "--help" {
            printInitUsage()
            return 0
        }

        let outputPath = arguments.first ?? "Untitled.dmgtemplate"
        return generateTemplate(at: outputPath)
    }

    // MARK: - Global Help

    static func printGlobalHelp() {
        let help = """
        Rilmazafone — DMG disk image builder
        
        Usage: Rilmazafone <command> [options]
        
        Commands:
          build   Build a DMG from a template
          init    Generate a starter template
        
        Run 'Rilmazafone <command> --help' for details on each command.
        Without a command, the GUI app launches normally.
        """
        fputs(help + "\n", stderr)
    }

    // MARK: - Argument Parsing

    static func parseBuildArguments(_ arguments: [String]) -> (template: String, output: String)? {
        guard arguments.count >= 3 else { return nil }

        let template = arguments[0]

        guard arguments[1] == "-o" || arguments[1] == "--output" else { return nil }
        let output = arguments[2]

        return (template, output)
    }

    private static func printBuildUsage() {
        let usage = """
        Usage: Rilmazafone build <template> -o <output.dmg>
        
        Build a DMG disk image from a .dmgtemplate directory.
        
        Arguments:
          <template>              Path to a .dmgtemplate directory
          -o, --output <path>     Output path for the DMG file
        
        Examples:
          Rilmazafone build MyApp.dmgtemplate -o dist/MyApp.dmg
          Rilmazafone build ~/Templates/release.dmgtemplate -o /tmp/Release.dmg
        """
        fputs(usage + "\n", stderr)
    }

    private static func printInitUsage() {
        let usage = """
        Usage: Rilmazafone init [output-path]
        
        Generate a starter .dmgtemplate directory with a default document.json.
        Edit the JSON to configure your DMG layout, then build with 'Rilmazafone build'.
        
        Arguments:
          [output-path]   Where to create the template (default: Untitled.dmgtemplate)
        
        Examples:
          Rilmazafone init
          Rilmazafone init MyApp.dmgtemplate
        """
        fputs(usage + "\n", stderr)
    }

    // MARK: - Template Generation

    static func generateTemplate(at path: String) -> Int32 {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default

        guard !fm.fileExists(atPath: url.path) else {
            error("Already exists: \(path)")
            return 1
        }

        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try fm.createDirectory(
                at: url.appending(path: "Assets"),
                withIntermediateDirectories: true
            )

            let config = DMGConfiguration()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: url.appending(path: "document.json"))

            progress("Created \(path)")
            progress("Edit document.json to configure your DMG, then run:")
            progress("  Rilmazafone build \(path) -o output.dmg")
            return 0
        } catch {
            Self.error("Failed to create template: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: - Build Pipeline

    private static func performBuild(templatePath: String, outputPath: String) async -> Int32 {
        let totalSteps = 7

        // Step 0: Load template
        progress("Loading template\u{2026}")
        let templateURL = URL(fileURLWithPath: templatePath)
        let outputURL = URL(fileURLWithPath: outputPath)

        guard FileManager.default.fileExists(atPath: templateURL.path) else {
            error("Template not found: \(templatePath)")
            return 1
        }

        let configuration: DMGConfiguration
        let assetsDirectory: URL

        do {
            (configuration, assetsDirectory) = try loadTemplate(at: templateURL)
        } catch {
            Self.error("Failed to load template: \(error.localizedDescription)")
            return 1
        }

        defer { try? FileManager.default.removeItem(at: assetsDirectory) }

        do {
            // Step 1: Estimate size
            progress("[\(1)/\(totalSteps)] Calculating size\u{2026}")
            let sizeEstimate = try estimateSize(for: configuration)

            // Step 2: Create writable DMG
            progress("[\(2)/\(totalSteps)] Creating disk image\u{2026}")
            let tempDMG = try await DMGBuilder.createWritableImage(
                volumeName: configuration.volumeName,
                size: sizeEstimate,
                filesystem: configuration.filesystem
            )

            // Step 3: Mount
            progress("[\(3)/\(totalSteps)] Mounting volume\u{2026}")
            let mountPoint = try await DMGBuilder.attach(tempDMG)
            var didDetach = false
            defer {
                if !didDetach {
                    let mp = mountPoint
                    Task { try? await DMGBuilder.detach(mp) }
                }
            }

            // Step 4: Copy content
            progress("[\(4)/\(totalSteps)] Copying files\u{2026}")
            let validItems = configuration.items.filter { item in
                if item.kind == .applicationsSymlink { return true }
                if item.linkType == .symlink, let target = item.sourcePath, !target.isEmpty { return true }
                if let path = item.sourcePath, FileManager.default.fileExists(atPath: path) { return true }
                return false
            }
            try await DMGBuilder.copyItems(validItems, to: mountPoint)

            // Step 5: Background + .DS_Store
            progress("[\(5)/\(totalSteps)] Configuring layout\u{2026}")
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

            // Step 6: Volume icon
            progress("[\(6)/\(totalSteps)] Setting volume icon\u{2026}")
            let volumeIconData = try await applyVolumeIcon(
                configuration: configuration,
                assetsDirectory: assetsDirectory,
                mountPoint: mountPoint
            )

            if configuration.filesystem == .hfsPlus {
                try? await DMGBuilder.bless(folder: mountPoint)
            }

            // Step 7: Detach, convert, optionally sign
            progress("[\(7)/\(totalSteps)] Compressing\u{2026}")
            try await DMGBuilder.detach(mountPoint)
            didDetach = true
            try await DMGBuilder.convert(
                source: tempDMG,
                destination: outputURL,
                format: configuration.dmgFormat
            )

            try? FileManager.default.removeItem(at: tempDMG)

            if configuration.codeSign.enabled {
                progress("Code signing\u{2026}")
                try await DMGBuilder.codeSign(
                    dmgPath: outputURL,
                    identity: configuration.codeSign.identity
                )
            }

            if let iconData = volumeIconData, let icon = NSImage(data: iconData) {
                NSWorkspace.shared.setIcon(icon, forFile: outputURL.path, options: [])
            }

            progress("Done: \(outputURL.path)")
            return 0

        } catch {
            Self.error(error.localizedDescription)
            return 1
        }
    }

    // MARK: - Template Loading

    /// Reads a `.dmgtemplate` package directory, decodes its configuration,
    /// and extracts embedded assets to a temporary directory.
    static func loadTemplate(at url: URL) throws -> (DMGConfiguration, URL) {
        let documentJSON = url.appending(path: "document.json")
        guard FileManager.default.fileExists(atPath: documentJSON.path) else {
            throw CLIError.missingManifest(url.lastPathComponent)
        }

        let data = try Data(contentsOf: documentJSON)
        var configuration = try JSONDecoder().decode(DMGConfiguration.self, from: data)
        configuration.expandAbbreviatedPaths()

        let assetsDir = FileManager.default.temporaryDirectory
            .appending(path: "rilmazafone-cli-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        let assetsSource = url.appending(path: "Assets")
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: assetsSource, includingPropertiesForKeys: nil
        ) {
            for fileURL in contents {
                let dest = assetsDir.appending(path: fileURL.lastPathComponent)
                try FileManager.default.copyItem(at: fileURL, to: dest)
            }
        }

        return (configuration, assetsDir)
    }

    // MARK: - Composite Background

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
                return nil
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

    static func estimateSize(for configuration: DMGConfiguration) throws -> String {
        var totalBytes: UInt64 = 32 * 1_024 * 1_024

        for item in configuration.items {
            guard item.kind != .applicationsSymlink else { continue }
            guard let path = item.sourcePath else { continue }

            let url = URL(fileURLWithPath: path)
            if let size = try? url.allocatedDirectorySize() {
                totalBytes += size
            }
        }

        totalBytes = UInt64(Double(totalBytes) * 1.5)

        let minimumBytes: UInt64 = configuration.filesystem == .apfs
            ? 128 * 1_024 * 1_024
            : 32 * 1_024 * 1_024
        totalBytes = max(totalBytes, minimumBytes)

        let megabytes = Int(totalBytes / (1_024 * 1_024))
        return "\(megabytes)m"
    }

    // MARK: - Output

    private static func progress(_ message: String) {
        fputs("rilmazafone: \(message)\n", stderr)
    }

    private static func error(_ message: String) {
        fputs("rilmazafone: error: \(message)\n", stderr)
    }

    // MARK: - Errors

    private enum CLIError: Error, LocalizedError {
        case missingManifest(String)

        var errorDescription: String? {
            switch self {
            case let .missingManifest(name):
                "No document.json found in \(name). Is this a valid .rilmazafone template?"
            }
        }
    }
}

// MARK: - URL Size Helper

private extension URL {
    nonisolated func allocatedDirectorySize() throws -> UInt64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }

        if !isDir.boolValue {
            let attrs = try fm.attributesOfItem(atPath: path)
            return attrs[.size] as? UInt64 ?? 0
        }

        var size: UInt64 = 0
        let enumerator = fm.enumerator(
            at: self,
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
