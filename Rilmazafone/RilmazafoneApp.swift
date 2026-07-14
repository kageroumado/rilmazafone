import SwiftUI

struct RilmazafoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Creating the registry at app init scans the template directories and
    /// pre-warms thumbnails, so the chooser opens instantly on first ⌘N.
    private let templateRegistry = TemplateRegistry.shared

    var body: some Scene {
        DocumentGroup(newDocument: {
            // AppKit instantiates the document shell on a background queue when
            // opening an existing file (Finder double-click, launch-by-document);
            // staged import/template results are only ever consumed on the
            // interactive main-thread new-document path.
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    if let imported = DMGImportCoordinator.shared.takePendingResult() {
                        RilmazafoneDocument(imported: imported)
                    } else {
                        RilmazafoneDocument()
                    }
                }
            } else {
                RilmazafoneDocument()
            }
        }) { file in
            DocumentContentView()
                .environment(file.document)
        }
        .defaultSize(width: 1_280, height: 720)
        // Launching with no document goes through the template chooser
        // (AppDelegate) instead of DocumentGroup's automatic untitled window.
        .defaultLaunchBehavior(.suppressed)
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
            SaveAsTemplateCommands()
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
            Button("Template from DMG\u{2026}") {
                TemplateSaveCoordinator.shared.createTemplateFromDMG()
            }
        }
    }
}

// MARK: - Save as Template

/// File → Save as Template…, placed with the save items and enabled only
/// while a document window is focused.
struct SaveAsTemplateCommands: Commands {
    @FocusedValue(\.document) private var document

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Button("Save as Template\u{2026}") {
                if let document {
                    TemplateSaveCoordinator.shared.saveAsTemplate(document)
                }
            }
            .disabled(document == nil)
        }
    }
}
