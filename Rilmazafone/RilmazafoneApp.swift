import SwiftUI

struct RilmazafoneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

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
            CommandGroup(after: .importExport) {
                Button("Import DMG\u{2026}") {
                    DMGImportCoordinator.shared.presentOpenPanel()
                }
            }
        }
    }
}
