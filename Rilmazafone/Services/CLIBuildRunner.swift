#if !APPSTORE
import Foundation

/// Headless DMG build runner for CLI invocation. GitHub build only —
/// the App Store build compiles this out and treats argv as a GUI launch.
///
/// Usage: `Rilmazafone build <template.dmgtemplate> -o <output.dmg>`
///
/// Handles CLI argument parsing, template loading, and stderr progress output,
/// delegating the actual build to the shared `DMGBuildPipeline`.
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
            try await DMGBuildPipeline.build(
                configuration: configuration,
                assetsDirectory: assetsDirectory,
                outputURL: outputURL,
                progress: { step in
                    Self.progress("[\(step.stepIndex)/\(step.totalSteps)] \(step.step)")
                }
            )
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

    // MARK: - Size Estimation

    /// Estimates the writable image size. Delegates to the shared pipeline;
    /// kept here as the CLI-facing entry point exercised by the test suite.
    static func estimateSize(for configuration: DMGConfiguration) throws -> String {
        try DMGBuildPipeline.estimateSize(for: configuration)
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
                "No document.json found in \(name). Is this a valid .dmgtemplate?"
            }
        }
    }
}
#endif
