import Foundation

/// Converts working designs into template form.
///
/// A template captures the *design* — layers, panels, window geometry, view
/// settings, background assets — but not the app that happened to fill it:
/// every app-kind item becomes an unfilled placeholder slot and the signing
/// configuration is reset, because the source path, bookmark, and identity all
/// belong to that specific app, not the layout. Shared by File → Save as
/// Template… and Template from DMG….
nonisolated enum TemplateSnapshot {
    /// Returns `configuration` in template form.
    ///
    /// App-kind items are replaced with fresh placeholders
    /// (``CanvasItem/appPlaceholder(label:position:)``) at the same position:
    /// the standard "Your App" label, no source path or bookmark, keeping any
    /// item panel the original carried. Code signing resets to the default
    /// (disabled, no identity). Everything else — non-app items, background,
    /// text and symbol layers, window, view settings, volume icon — passes
    /// through unchanged.
    static func templateConfiguration(from configuration: DMGConfiguration) -> DMGConfiguration {
        var template = configuration
        template.items = configuration.items.map { item in
            guard item.kind == .app else { return item }
            var placeholder = CanvasItem.appPlaceholder(position: item.position)
            placeholder.background = item.background
            return placeholder
        }
        template.codeSign = CodeSignConfiguration()
        return template
    }

    /// The asset filenames `configuration` references: every background image
    /// layer plus the custom volume icon, when present. Used to copy exactly
    /// the assets a template needs, leaving stale document assets behind.
    static func referencedAssetNames(in configuration: DMGConfiguration) -> Set<String> {
        var names = Set(configuration.background.layers.map(\.imageName))
        if let iconName = configuration.volumeIcon.sourceIconName {
            names.insert(iconName)
        }
        return names
    }
}

extension RilmazafoneDocument {
    /// Snapshot of the current design in template form: the converted
    /// configuration plus the asset payloads it references, ready for
    /// ``TemplateRegistry/saveUserTemplate(named:configuration:assets:)``.
    func templateSnapshot() -> (configuration: DMGConfiguration, assets: [String: Data]) {
        let template = TemplateSnapshot.templateConfiguration(from: configuration)
        var assets: [String: Data] = [:]
        if let wrappers = assetsWrapper?.fileWrappers {
            for name in TemplateSnapshot.referencedAssetNames(in: template) {
                if let data = wrappers[name]?.regularFileContents {
                    assets[name] = data
                }
            }
        }
        return (template, assets)
    }
}
