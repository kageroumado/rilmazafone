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
    /// layer, the custom volume icon, and every embedded item payload, when
    /// present. Used to copy exactly the assets a template needs, leaving
    /// stale document assets behind.
    static func referencedAssetNames(in configuration: DMGConfiguration) -> Set<String> {
        var names = Set(configuration.background.layers.map(\.imageName))
        if let iconName = configuration.volumeIcon.sourceIconName {
            names.insert(iconName)
        }
        for item in configuration.items {
            if let assetName = item.assetName {
                names.insert(assetName)
            }
        }
        return names
    }

    // MARK: - Embedding

    /// Converts externally-referenced non-app copy items into portable form:
    /// sources at or under ``EmbeddedAssets/sizeCap`` are embedded as payloads
    /// (path and bookmark stripped — a document-scoped bookmark is dead weight
    /// in any other document, and a raw path is machine-specific); larger or
    /// unreachable sources become typed placeholder slots that keep the item's
    /// label, position, and panel. Already-embedded items, symlink-type items,
    /// placeholders, and the Applications symlink pass through unchanged.
    ///
    /// Returns the rewritten items plus the new payloads keyed by asset name.
    static func embedItems(
        _ items: [CanvasItem],
        documentURL: URL?,
    ) -> (items: [CanvasItem], payloads: [String: Data]) {
        var payloads: [String: Data] = [:]
        let embedded = items.map { item -> CanvasItem in
            guard item.kind == .file || item.kind == .folder,
                  item.linkType == .copy,
                  !item.isPlaceholder,
                  !item.isEmbedded
            else { return item }

            let payload = SourceAccess.withScope(item: item, documentURL: documentURL) { url -> Data? in
                guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
                return try? EmbeddedAssets.payload(for: url, kind: item.kind)
            }

            if let payload {
                var portable = item
                let assetName = EmbeddedAssets.assetName(
                    itemID: item.id, label: item.label, kind: item.kind,
                )
                portable.assetName = assetName
                portable.sourcePath = nil
                portable.sourceBookmark = nil
                payloads[assetName] = payload
                return portable
            }

            var slot = item.kind == .folder
                ? CanvasItem.folderPlaceholder(label: item.label, position: item.position)
                : CanvasItem.filePlaceholder(label: item.label, position: item.position)
            slot.background = item.background
            return slot
        }
        return (embedded, payloads)
    }
}

extension RilmazafoneDocument {
    /// Snapshot of the current design in template form: the converted
    /// configuration plus the asset payloads it references — background
    /// images, volume icon, item payloads embedded by this snapshot, and
    /// item payloads the document already carried — ready for
    /// ``TemplateRegistry/saveUserTemplate(named:configuration:assets:)``.
    func templateSnapshot() -> (configuration: DMGConfiguration, assets: [String: Data]) {
        var template = TemplateSnapshot.templateConfiguration(from: configuration)
        let embedding = TemplateSnapshot.embedItems(template.items, documentURL: fileURL)
        template.items = embedding.items

        var assets = embedding.payloads
        if let wrappers = assetsWrapper?.fileWrappers {
            for name in TemplateSnapshot.referencedAssetNames(in: template)
                where assets[name] == nil {
                if let data = wrappers[name]?.regularFileContents {
                    assets[name] = data
                }
            }
        }
        return (template, assets)
    }
}
