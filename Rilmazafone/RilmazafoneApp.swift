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

                #if !APPSTORE
                    Divider()
                    NewReleasePlanButton()
                #endif
            }
            SaveAsTemplateCommands()
            CommandGroup(after: .importExport) {
                Button("Import DMG\u{2026}") {
                    DMGImportCoordinator.shared.presentOpenPanel()
                }
            }
            #if !APPSTORE
                ReleaseCommands()
            #endif
        }

        #if !APPSTORE
            DocumentGroup(newDocument: { ReleasePlanDocument() }) { file in
                ReleasePlanContentView()
                    .environment(file.document)
            }
            .defaultSize(width: 880, height: 620)
            .defaultLaunchBehavior(.suppressed)
        #endif

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

#if !APPSTORE
    // MARK: - New Release Plan

    /// Command-menu button for the second document type. A plain View so it can
    /// reach the `newDocument` environment action, which Commands themselves
    /// can't.
    struct NewReleasePlanButton: View {
        @Environment(\.newDocument) private var newDocument

        var body: some View {
            Button("New Release Plan") {
                newDocument { ReleasePlanDocument() }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }

    // MARK: - Release Menu

    /// Menu-bar counterparts of the plan window's toolbar actions — a toolbar
    /// item can't be a command's only home.
    struct ReleaseCommands: Commands {
        @FocusedValue(\.releasePlanActions) private var actions

        var body: some Commands {
            CommandMenu("Release") {
                Button("Build Release") {
                    actions?.build()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(actions?.canRun != true)

                Button("Publish") {
                    actions?.publish()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(actions?.canRun != true)
            }
        }
    }
#endif

// MARK: - Save as Template

/// File → Save as Template… (and Save as Release Plan…), enabled only while
/// a design document window is focused.
///
/// Anchored to `.importExport`, NOT `.saveItem`: with a second
/// `DocumentGroup` in the app, SwiftUI silently discards command groups
/// anchored to the save-item section. The import/export section keeps them,
/// and the resulting menu order matches the original placement anyway.
struct SaveAsTemplateCommands: Commands {
    @FocusedValue(\.document) private var document

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Save as Template\u{2026}") {
                if let document {
                    TemplateSaveCoordinator.shared.saveAsTemplate(document)
                }
            }
            .disabled(document == nil)

            #if !APPSTORE
                Button("Save as Release Plan\u{2026}") {
                    if let document {
                        ReleasePlanCreator.createFromDesign(document)
                    }
                }
                .disabled(document == nil)
            #endif
        }
    }
}
