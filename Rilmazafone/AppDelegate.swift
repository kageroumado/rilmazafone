import AppKit

/// Provides the Dock icon's context menu: New Document plus the shared
/// recent-documents list from `NSDocumentController`.
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

        // "New from Template…" is added here in Phase 3, driven by the same
        // template registry as the chooser and the File menu.

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
