import SwiftUI

// MARK: - Canvas Toolbar

struct CanvasToolbar: ToolbarContent {
    @Binding var zoom: CGFloat
    @Binding var isFitToWindow: Bool
    @Binding var prefersDarkAppearance: Bool

    private let zoomPresets: [CGFloat] = [0.25, 0.50, 0.75, 1.0, 1.25, 1.50, 2.0]

    var body: some ToolbarContent {
        ToolbarItem {
            Picker("Appearance", selection: $prefersDarkAppearance) {
                Image(systemName: "sun.max.fill").tag(false)
                Image(systemName: "moon.fill").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Preview Appearance")
        }

        ToolbarItem {
            Menu {
                ForEach(zoomPresets, id: \.self) { preset in
                    Button("\(Int(preset * 100))%") {
                        isFitToWindow = false
                        zoom = preset
                    }
                }
                Divider()
                Button("Fit to Window") {
                    isFitToWindow = true
                }
            } label: {
                Text(zoomLabel)
                    .monospacedDigit()
            }
            .menuIndicator(.visible)
            .help("Canvas Zoom")
        }
    }

    private var zoomLabel: String {
        isFitToWindow ? " Fit " : "\(Int(zoom * 100))%"
    }
}

// MARK: - Inspector Toolbar

struct InspectorToolbar: ToolbarContent {
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(BuildManager.self) private var buildManager
    @Binding var inspectorTab: InspectorTab
    var onBuild: () -> Void

    var body: some ToolbarContent {
        ToolbarSpacer(.flexible)

        ToolbarItem {
            Picker("Inspector", selection: $inspectorTab) {
                Label("DMG", systemImage: "doc.text")
                    .tag(InspectorTab.dmg)
                Label("Canvas", systemImage: "paintbrush")
                    .tag(InspectorTab.canvas)
                Label("Element", systemImage: "square.on.square")
                    .tag(InspectorTab.element)
            }
            .pickerStyle(.segmented)
            .help("Switch between Element, Canvas, and DMG settings")
        }

        ToolbarItem {
            Button {
                onBuild()
            } label: {
                Label("Create", systemImage: "externaldrive.fill")
            }
            .buttonStyle(.borderedProminent)
            .labelStyle(.titleAndIcon)
            .help("Create DMG")
            .disabled(!document.hasApp || buildManager.isBuilding)
        }
    }
}
