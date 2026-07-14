import AppKit
import UniformTypeIdentifiers

/// Routes app activation with no windows into the template chooser and
/// provides the Dock icon's context menu: New Document, the registry-driven
/// "New from Template" submenu, and the shared recent-documents list from
/// `NSDocumentController`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum Constants {
        /// Maximum number of recent documents shown in the Dock menu.
        static let maximumRecentDocuments = 10
        /// Standard menu item icon size.
        static let menuIconSize = NSSize(width: 16, height: 16)
        /// How long after launch to wait before concluding nothing is opening.
        static let launchSettleDelay: TimeInterval = 0.2
        /// Inset around the launch panel's New Document accessory button.
        static let accessoryPadding: CGFloat = 8
    }

    // MARK: - Launch & Reopen

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The system's app-centric launch panel is swallowed by the suppressed
        // DocumentGroup scene (like every other no-document launch path), so
        // it is kept off and `presentLaunchOpenPanel()` provides the
        // equivalent picker deterministically in both build flavors.
        UserDefaults.standard.register(defaults: [
            "NSShowAppCentricOpenPanelInsteadOfUntitledFile": false,
        ])
    }

    /// Launching (and Dock-clicking) with no open documents shows the open
    /// panel, Pages-style; document creation lives behind its New Document
    /// button rather than opening the template chooser uninvited.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        presentLaunchOpenPanel()
        return false
    }

    /// The DocumentGroup scene's automatic untitled window is suppressed
    /// (`defaultLaunchBehavior(.suppressed)`), and a suppressed SwiftUI scene
    /// also swallows AppKit's no-document launch path — so present the open
    /// panel here unless this launch is opening or restoring something. The
    /// delay lets documents double-clicked in Finder create their windows
    /// first.
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.launchSettleDelay) {
            let hasContent = NSApp.windows.contains(where: \.isVisible)
                || !NSDocumentController.shared.documents.isEmpty
            guard !hasContent else { return }
            self.presentLaunchOpenPanel()
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        guard !hasVisibleWindows else { return true }
        presentLaunchOpenPanel()
        return false
    }

    /// Nil-targeted `newDocument:` actions dispatch to the app delegate before
    /// `NSDocumentController`, so any stray one follows the same
    /// chooser-or-blank policy as ⌘N instead of creating a bare untitled
    /// document. Direct calls to `NSDocumentController.newDocument(_:)` (the
    /// blank-document path) are unaffected.
    @objc func newDocument(_ sender: Any?) {
        TemplateChooserController.shared.newDocument()
    }

    // MARK: - Launch Open Panel

    private var launchOpenPanel: NSOpenPanel?

    /// The launch picker: the standard document open panel with a leading
    /// "New Document" button — the app's stand-in for the system app-centric
    /// launch panel, which the suppressed scene never lets appear. New
    /// Document dismisses the panel and follows the ⌘N chooser policy.
    private func presentLaunchOpenPanel() {
        if let panel = launchOpenPanel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.rilmazafoneDocument]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.accessoryView = launchPanelAccessory()
        panel.isAccessoryViewDisclosed = true

        launchOpenPanel = panel
        panel.begin { [weak self] response in
            guard let self else { return }
            launchOpenPanel = nil
            guard response == .OK else { return }
            for url in panel.urls {
                NSDocumentController.shared.openDocument(
                    withContentsOf: url, display: true
                ) { _, _, _ in }
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// A full-width strip holding the leading New Document button, so the
    /// panel does not center the bare button.
    private func launchPanelAccessory() -> NSView {
        let button = NSButton(
            title: "New Document",
            target: self,
            action: #selector(newDocumentFromLaunchPanel(_:))
        )
        button.sizeToFit()

        let container = NSView(frame: NSRect(
            x: 0, y: 0,
            width: 400,
            height: button.frame.height + 2 * Constants.accessoryPadding
        ))
        container.autoresizingMask = [.width]
        button.setFrameOrigin(NSPoint(
            x: Constants.accessoryPadding, y: Constants.accessoryPadding
        ))
        button.autoresizingMask = [.maxXMargin]
        container.addSubview(button)
        return container
    }

    @objc private func newDocumentFromLaunchPanel(_ sender: Any?) {
        launchOpenPanel?.cancel(sender)
        TemplateChooserController.shared.newDocument()
    }

    // MARK: - Dock Menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let newDocument = NSMenuItem(
            title: "New Document",
            action: #selector(newDocumentFollowingPolicy(_:)),
            keyEquivalent: ""
        )
        newDocument.target = self
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

    /// Dock menu "New Document": same chooser-or-blank policy as ⌘N.
    @objc func newDocumentFollowingPolicy(_ sender: NSMenuItem) {
        TemplateChooserController.shared.newDocument()
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
