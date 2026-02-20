import AppKit
import SwiftUI

struct InspectorView: View {
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager
    @Binding var selectedItemID: UUID?
    @Binding var tab: InspectorTab

    var body: some View {
        // Keep all three tabs alive to avoid destroying/recreating
        // expensive Form views on every tab switch. Form with .grouped
        // style triggers ~2000 layout updates per construction.
        ZStack {
            canvasTab
                .opacity(tab == .canvas ? 1 : 0)
                .disabled(tab != .canvas)
                .accessibilityHidden(tab != .canvas)

            dmgTab
                .opacity(tab == .dmg ? 1 : 0)
                .disabled(tab != .dmg)
                .accessibilityHidden(tab != .dmg)

            elementTab
                .opacity(tab == .element ? 1 : 0)
                .disabled(tab != .element)
                .accessibilityHidden(tab != .element)
        }
    }

    // MARK: - Element Tab

    private enum ResolvedElement: Equatable {
        case backgroundLayer(BackgroundLayer)
        case textLayer(TextLayerConfiguration)
        case sfSymbolLayer(SFSymbolLayerConfiguration)
        case item(CanvasItem)
        case none
    }

    private enum ElementKind: Equatable {
        case backgroundLayer
        case textLayer
        case sfSymbolLayer
        case item
        case none
    }

    private var resolvedElement: ResolvedElement {
        guard let id = selectedItemID else { return .none }
        if let layer = document.backgroundLayer(for: id) {
            return .backgroundLayer(layer)
        }
        if let textLayer = document.textLayer(for: id) {
            return .textLayer(textLayer)
        }
        if let sfLayer = document.sfSymbolLayer(for: id) {
            return .sfSymbolLayer(sfLayer)
        }
        if let item = document.configuration.items.first(where: { $0.id == id }) {
            return .item(item)
        }
        return .none
    }

    private var activeElementKind: ElementKind {
        switch resolvedElement {
        case .backgroundLayer: .backgroundLayer
        case .textLayer: .textLayer
        case .sfSymbolLayer: .sfSymbolLayer
        case .item: .item
        case .none: .none
        }
    }

    // Cached data keeps inactive inspector Forms alive between type switches.
    // Active inspectors read fresh data from resolvedElement; cached data is
    // the fallback so the hidden Form isn't destroyed when its optional goes nil.
    @State private var cachedItem: CanvasItem?
    @State private var cachedBackgroundLayer: BackgroundLayer?
    @State private var cachedTextLayer: TextLayerConfiguration?
    @State private var cachedSFSymbolLayer: SFSymbolLayerConfiguration?

    private var displayedItem: CanvasItem? {
        if case let .item(item) = resolvedElement { return item }
        return cachedItem
    }

    private var displayedBackgroundLayer: BackgroundLayer? {
        if case let .backgroundLayer(layer) = resolvedElement { return layer }
        return cachedBackgroundLayer
    }

    private var displayedTextLayer: TextLayerConfiguration? {
        if case let .textLayer(layer) = resolvedElement { return layer }
        return cachedTextLayer
    }

    private var displayedSFSymbolLayer: SFSymbolLayerConfiguration? {
        if case let .sfSymbolLayer(layer) = resolvedElement { return layer }
        return cachedSFSymbolLayer
    }

    private func updateElementCache(_ element: ResolvedElement) {
        switch element {
        case let .item(item): cachedItem = item
        case let .backgroundLayer(layer): cachedBackgroundLayer = layer
        case let .textLayer(layer): cachedTextLayer = layer
        case let .sfSymbolLayer(layer): cachedSFSymbolLayer = layer
        case .none: break
        }
    }

    @ViewBuilder
    private var elementTab: some View {
        let kind = activeElementKind

        ZStack {
            if let item = displayedItem {
                Form {
                    ItemInspector(item: item)
                }
                .formStyle(.grouped)
                .opacity(kind == .item ? 1 : 0)
                .disabled(kind != .item)
                .accessibilityHidden(kind != .item)
            }

            if let layer = displayedBackgroundLayer {
                Form {
                    ImageLayerInspector(layer: layer, selectedItemID: $selectedItemID)
                    LayerEffectsSection(layer: layer)
                }
                .formStyle(.grouped)
                .opacity(kind == .backgroundLayer ? 1 : 0)
                .disabled(kind != .backgroundLayer)
                .accessibilityHidden(kind != .backgroundLayer)
            }

            if let layer = displayedTextLayer {
                Form {
                    TextLayerInspector(layer: layer, selectedItemID: $selectedItemID)
                }
                .formStyle(.grouped)
                .opacity(kind == .textLayer ? 1 : 0)
                .disabled(kind != .textLayer)
                .accessibilityHidden(kind != .textLayer)
            }

            if let layer = displayedSFSymbolLayer {
                Form {
                    SFSymbolLayerInspector(layer: layer, selectedItemID: $selectedItemID)
                }
                .formStyle(.grouped)
                .opacity(kind == .sfSymbolLayer ? 1 : 0)
                .disabled(kind != .sfSymbolLayer)
                .accessibilityHidden(kind != .sfSymbolLayer)
            }

            if kind == .none {
                noSelectionPlaceholder
            }
        }
        .onChange(of: resolvedElement, initial: true) {
            updateElementCache(resolvedElement)
        }
    }

    private var noSelectionPlaceholder: some View {
        ContentUnavailableView {
            Label("No Selection", systemImage: "square.dashed")
        }
    }

    // MARK: - Canvas Tab

    private var canvasTab: some View {
        Form {
            BackgroundSection()
            IconAppearanceSection()

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    undoManager?.beginUndoGrouping()
                    document.setWindowSize(width: 660, height: 400, undoManager: undoManager)
                    document.setIconSize(160, undoManager: undoManager)
                    document.setTextSize(13, undoManager: undoManager)
                    document.setGridSpacing(100, undoManager: undoManager)
                    document.setGridSpacingAuto(true, undoManager: undoManager)
                    document.setHideExtensions(true, undoManager: undoManager)
                    document.setBackgroundType(.none, undoManager: undoManager)
                    undoManager?.endUndoGrouping()
                    undoManager?.setActionName("Reset Appearance")
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - DMG Tab

    private var dmgTab: some View {
        Form {
            DMGSettingsSection()
            BuildSettingsSection()

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    undoManager?.beginUndoGrouping()
                    document.setVolumeName("Untitled", undoManager: undoManager)
                    document.setDMGFormat(.ulfo, undoManager: undoManager)
                    document.setFilesystem(.apfs, undoManager: undoManager)
                    document.setCodeSignEnabled(false, undoManager: undoManager)
                    document.setVolumeIconType(.composed, undoManager: undoManager)
                    undoManager?.endUndoGrouping()
                    undoManager?.setActionName("Reset DMG Settings")
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }
}
