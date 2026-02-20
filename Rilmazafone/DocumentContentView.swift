import SwiftUI
import UniformTypeIdentifiers

// MARK: - Inspector Tab

enum InspectorTab: Hashable {
    case dmg // DMG settings + build settings
    case canvas // Window, background, icon appearance
    case element // Selected item/layer properties and effects
}

// MARK: - Content View

struct DocumentContentView: View {
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager
    @State private var buildManager = BuildManager()
    @State private var selectedItemID: UUID?
    @State private var isInspectorPresented = true
    @State private var inspectorTab: InspectorTab = .dmg
    @State private var zoom: CGFloat = 1.0
    @State private var isFitToWindow = false
    @State private var prefersDarkAppearance = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedItemID: $selectedItemID)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            CanvasView(
                selectedItemID: $selectedItemID,
                zoom: $zoom,
                isFitToWindow: $isFitToWindow,
                prefersDarkAppearance: prefersDarkAppearance
            )
            .toolbar {
                CanvasToolbar(
                    zoom: $zoom,
                    isFitToWindow: $isFitToWindow,
                    prefersDarkAppearance: $prefersDarkAppearance
                )
            }
        }
        .inspector(isPresented: $isInspectorPresented) {
            InspectorView(selectedItemID: $selectedItemID, tab: $inspectorTab)
                .inspectorColumnWidth(min: 250, ideal: 285, max: 350)
                .toolbar {
                    InspectorToolbar(inspectorTab: $inspectorTab, onBuild: { startBuild() })
                }
        }
        .sheet(isPresented: Binding(
            get: { buildManager.isShowingSheet },
            set: { if !$0 { buildManager.reset() } }
        )) {
            BuildSheet()
        }
        .environment(buildManager)
        .frame(minWidth: 900, minHeight: 600)
        .onDeleteCommand {
            if let id = selectedItemID {
                if document.backgroundLayer(for: id) != nil {
                    document.removeBackgroundLayer(id, undoManager: undoManager)
                } else if document.textLayer(for: id) != nil {
                    document.removeTextLayer(id, undoManager: undoManager)
                } else if document.sfSymbolLayer(for: id) != nil {
                    document.removeSFSymbolLayer(id, undoManager: undoManager)
                } else {
                    document.removeItem(id, undoManager: undoManager)
                }
                selectedItemID = nil
            }
        }
    }

    private func startBuild() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType("com.apple.disk-image") ?? .data]
        panel.nameFieldStringValue = "\(document.configuration.volumeName).dmg"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let assetsDir = try document.extractAssetsToTemporaryDirectory()
            buildManager.build(
                configuration: document.configuration,
                assetsDirectory: assetsDir,
                outputURL: url
            )
        } catch {
            buildManager.reportError(error.localizedDescription)
        }
    }
}
