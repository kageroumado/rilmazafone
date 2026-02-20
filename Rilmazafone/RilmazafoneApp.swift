import SwiftUI

struct RilmazafoneApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { RilmazafoneDocument() }) { file in
            DocumentContentView()
                .environment(file.document)
        }
        .defaultSize(width: 1_280, height: 720)
        .commands {
            SidebarCommands()
            InspectorCommands()
        }
    }
}
