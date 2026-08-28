import SwiftUI

// MARK: - Canvas Toolbar

struct CanvasToolbar: ToolbarContent {
    @Binding var zoom: CGFloat
    @Binding var isFitToWindow: Bool
    @Binding var prefersDarkAppearance: Bool

    private let zoomPresets: [CGFloat] = [0.25, 0.50, 0.75, 1.0, 1.25, 1.50, 2.0]

    var body: some ToolbarContent {
        ToolbarItem {
            LegibilityWarningChip()
        }

        ToolbarItem {
            Picker("Appearance", selection: $prefersDarkAppearance) {
                Image(systemName: "sun.max.fill")
                    .accessibilityLabel("Light Appearance")
                    .tag(false)
                Image(systemName: "moon.fill")
                    .accessibilityLabel("Dark Appearance")
                    .tag(true)
            }
            .pickerStyle(.segmented)
            .help(
                "Preview the Finder window's chrome. A background picture keeps its "
                    + "Light Mode rendering, so the background and labels do not change.",
            )
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
                    .frame(minWidth: Self.zoomLabelMinimumWidth)
            }
            .menuIndicator(.visible)
            .help("Canvas Zoom")
        }
    }

    /// Holds the menu's width steady across "Fit" and the percentages, so the toolbar
    /// does not reflow as the zoom changes.
    private static let zoomLabelMinimumWidth: CGFloat = 34

    private var zoomLabel: String {
        isFitToWindow ? "Fit" : "\(Int(zoom * 100))%"
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
                    .accessibilityLabel("DMG Settings")
                    .tag(InspectorTab.dmg)
                Label("Canvas", systemImage: "paintbrush")
                    .accessibilityLabel("Canvas Settings")
                    .tag(InspectorTab.canvas)
                Label("Element", systemImage: "square.on.square")
                    .accessibilityLabel("Element Settings")
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
            .buttonStyle(.glassProminent)
            .labelStyle(.titleAndIcon)
            .help("Create DMG")
            .disabled(!document.hasApp || buildManager.isBuilding)
        }
    }
}
