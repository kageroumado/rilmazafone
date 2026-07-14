import SwiftUI

struct RilmazafoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Creating the registry at app init scans the template directories and
    /// pre-warms thumbnails, so the chooser opens instantly on first ⌘N.
    private let templateRegistry = TemplateRegistry.shared

    var body: some Scene {
        DocumentGroup(newDocument: {
            // Document creation always happens on the main thread; the closure
            // is merely typed @Sendable.
            MainActor.assumeIsolated {
                if let imported = DMGImportCoordinator.shared.takePendingResult() {
                    return RilmazafoneDocument(imported: imported)
                }
                return RilmazafoneDocument()
            }
        }) { file in
            DocumentContentView()
                .environment(file.document)
        }
        .defaultSize(width: 1_280, height: 720)
        .commands {
            SidebarCommands()
            InspectorCommands()
            CommandGroup(replacing: .newItem) {
                Button("New") {
                    TemplateChooserController.shared.newDocument()
                }
                .keyboardShortcut("n", modifiers: .command)

                newFromTemplateMenu
            }
            CommandGroup(after: .importExport) {
                Button("Import DMG\u{2026}") {
                    DMGImportCoordinator.shared.presentOpenPanel()
                }
            }
        }

        Settings {
            SettingsView()
        }
    }

    /// File → New from Template: bundled templates, user templates, and the
    /// chooser — driven by the shared registry so it always matches the
    /// chooser and the Dock menu.
    private var newFromTemplateMenu: some View {
        Menu("New from Template") {
            ForEach(templateRegistry.bundled) { entry in
                Button(entry.name) {
                    TemplateChooserController.shared.createDocument(from: entry)
                }
            }
            if !templateRegistry.user.isEmpty {
                Divider()
                ForEach(templateRegistry.user) { entry in
                    Button(entry.name) {
                        TemplateChooserController.shared.createDocument(from: entry)
                    }
                }
            }
            Divider()
            Button("Template Chooser\u{2026}") {
                TemplateChooserController.shared.show()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
        }
    }
}
