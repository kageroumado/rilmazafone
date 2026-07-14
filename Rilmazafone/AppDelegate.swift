import AppKit

/// Provides the Dock icon's context menu: New Document, the registry-driven
/// "New from Template" submenu, and the shared recent-documents list from
/// `NSDocumentController`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Constants {
        /// Maximum number of recent documents shown in the Dock menu.
        static let maximumRecentDocuments = 10
        /// Standard menu item icon size.
        static let menuIconSize = NSSize(width: 16, height: 16)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let newDocument = NSMenuItem(
            title: "New Document",
            action: #selector(NSDocumentController.newDocument(_:)),
            keyEquivalent: ""
        )
        newDocument.target = NSDocumentController.shared
        menu.addItem(newDocument)

        if let templates = newFromTemplateItem() {
            menu.addItem(templates)
        }

        let recents = NSDocumentController.shared.recentDocumentURLs
            .prefix(Constants.maximumRecentDocuments)
        if !recents.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Recent Documents"))
            for url in recents {
                menu.addItem(recentDocumentItem(for: url))
            }
        }

        return menu
    }

    // MARK: - Templates

    /// "New from Template" submenu listing bundled then user templates from
    /// the shared registry, matching the File menu and chooser. Returns `nil`
    /// when no templates exist. The Dock menu is rebuilt on every open, so it
    /// always reflects the registry's current state.
    private func newFromTemplateItem() -> NSMenuItem? {
        let registry = TemplateRegistry.shared
        guard !(registry.bundled.isEmpty && registry.user.isEmpty) else { return nil }

        let submenu = NSMenu(title: "New from Template")
        for entry in registry.bundled {
            submenu.addItem(templateItem(for: entry))
        }
        if !registry.user.isEmpty {
            if !registry.bundled.isEmpty {
                submenu.addItem(.separator())
            }
            for entry in registry.user {
                submenu.addItem(templateItem(for: entry))
            }
        }

        let item = NSMenuItem(title: "New from Template", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// `NSMenuItem.target` is weak, so the items target the app delegate
    /// itself, which the application retains for its whole lifetime.
    private func templateItem(for entry: TemplateEntry) -> NSMenuItem {
        let item = NSMenuItem(
            title: entry.name,
            action: #selector(newDocumentFromTemplate(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = entry
        return item
    }

    @objc func newDocumentFromTemplate(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? TemplateEntry else { return }
        TemplateChooserController.shared.createDocument(from: entry)
    }

    // MARK: - Recents

    private func recentDocumentItem(for url: URL) -> NSMenuItem {
        let item = NSMenuItem(
            title: FileManager.default.displayName(atPath: url.path),
            action: #selector(openRecentDocument(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = url

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = Constants.menuIconSize
        item.image = icon

        return item
    }

    @objc func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(
            withContentsOf: url, display: true
        ) { _, _, _ in }
    }
}
