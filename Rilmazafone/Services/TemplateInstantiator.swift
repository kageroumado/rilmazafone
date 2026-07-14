import Foundation

/// Loads `.dmgtemplate` packages into the same ``DMGImporter/Result`` shape
/// the DMG import flow stages, so template instantiation rides the existing
/// `DMGImportCoordinator` → `DocumentGroup` path and untitled semantics,
/// autosave, and recents behave normally.
nonisolated enum TemplateInstantiator {
    // MARK: - Errors

    enum TemplateError: Error, LocalizedError {
        /// The package has no readable `document.json`.
        case unreadableTemplate(URL)

        var errorDescription: String? {
            switch self {
            case let .unreadableTemplate(url):
                "The template \u{201C}\(url.deletingPathExtension().lastPathComponent)\u{201D} could not be read."
            }
        }
    }

    // MARK: - Loading

    /// Decodes the template's configuration from its `document.json`,
    /// expanding `~`-abbreviated source paths like the document read path.
    static func configuration(ofTemplateAt url: URL) throws -> DMGConfiguration {
        let manifestURL = url.appending(path: "document.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw TemplateError.unreadableTemplate(url)
        }
        var configuration = try JSONDecoder().decode(DMGConfiguration.self, from: data)
        configuration.expandAbbreviatedPaths()
        return configuration
    }

    /// Loads every asset payload from the template's `Assets` directory,
    /// keyed by filename. Missing directory yields an empty dictionary.
    static func assets(ofTemplateAt url: URL) -> [String: Data] {
        let assetsDirectory = url.appending(path: "Assets", directoryHint: .isDirectory)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: assetsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
        ) else { return [:] }

        var assets: [String: Data] = [:]
        for fileURL in contents {
            if let data = try? Data(contentsOf: fileURL) {
                assets[fileURL.lastPathComponent] = data
            }
        }
        return assets
    }

    // MARK: - Instantiation

    /// Builds a stageable result from a template: its configuration (window
    /// size overridden when the chooser picked one, placeholder items intact)
    /// plus its asset payloads.
    static func instantiate(
        templateAt url: URL,
        windowSizeOverride: CGSize? = nil,
    ) throws -> DMGImporter.Result {
        var configuration = try configuration(ofTemplateAt: url)
        if let size = windowSizeOverride {
            configuration.window.width = size.width
            configuration.window.height = size.height
        }
        return DMGImporter.Result(
            configuration: configuration,
            assets: assets(ofTemplateAt: url),
        )
    }

    /// A blank document configuration carrying a non-default window size
    /// chosen in the template chooser.
    static func blank(windowSize: CGSize) -> DMGImporter.Result {
        var configuration = DMGConfiguration()
        configuration.window.width = windowSize.width
        configuration.window.height = windowSize.height
        return DMGImporter.Result(configuration: configuration)
    }
}
