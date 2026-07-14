import SwiftUI
import UniformTypeIdentifiers

// MARK: - Inspector Tab

enum InspectorTab: Hashable {
    case dmg // DMG settings + build settings
    case canvas // Window, background, icon appearance
    case element // Selected item/layer properties and effects
}

// MARK: - Focused Document

extension FocusedValues {
    /// The document of the focused (key) document window, published by
    /// `DocumentContentView` so document-scoped menu commands (File → Save as
    /// Template…) can reach it and disable themselves when no document is
    /// focused.
    @Entry var document: RilmazafoneDocument?
}

// MARK: - Content View

struct DocumentContentView: View {
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager
    @Environment(\.documentConfiguration) private var documentConfiguration
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var buildManager = BuildManager()
    @State private var selectedItemID: UUID?
    @State private var isInspectorPresented = true
    @State private var inspectorTab: InspectorTab = .dmg
    @State private var zoom: CGFloat = 1.0
    @State private var isFitToWindow = false

    /// The user's explicit canvas appearance choice, or `nil` to follow the
    /// system appearance (the default on open).
    @State private var appearanceOverride: Bool?

    private var prefersDarkAppearance: Bool {
        appearanceOverride ?? (systemColorScheme == .dark)
    }

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
                    prefersDarkAppearance: Binding(
                        get: { prefersDarkAppearance },
                        set: { appearanceOverride = $0 }
                    )
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
        .focusedSceneValue(\.document, document)
        .frame(minWidth: 900, minHeight: 600)
        .onChange(of: documentConfiguration?.fileURL, initial: true) { _, newURL in
            document.documentFileURLDidChange(newURL)
        }
        .task(id: legibilityAnalysisGeneration) {
            await refreshLegibilityWarnings()
        }
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

    // MARK: - Label Legibility

    /// Debounce interval between a background/position-affecting edit and the
    /// off-main legibility analysis pass.
    private static let legibilityDebounce: Duration = .milliseconds(300)

    /// Fingerprint of every input to the legibility analysis: the composited
    /// background (base, layers, text, symbols, window size), icon/text metrics,
    /// and the items themselves — unlike the panel-backdrop cache, item positions
    /// and panels DO matter here, so `itemsGeneration` is included. Built from the
    /// document's slice generation counters instead of deep-hashing content, so
    /// evaluating it is O(1) in document size.
    private var legibilityAnalysisGeneration: Int {
        var hasher = Hasher()
        hasher.combine(document.itemsGeneration)
        hasher.combine(document.backgroundGeneration)
        hasher.combine(document.textLayersGeneration)
        hasher.combine(document.sfSymbolLayersGeneration)
        hasher.combine(document.restGeneration)
        hasher.combine(document.imagesGeneration)
        return hasher.finalize()
    }

    /// Debounced, off-main legibility refresh. `.task(id:)` cancels the previous
    /// invocation on every generation change, so the sleep acts as the debounce:
    /// rapid edits keep cancelling before any compositing work starts, and edit
    /// latency stays untouched.
    private func refreshLegibilityWarnings() async {
        guard !document.items.isEmpty else {
            document.legibilityWarnings = []
            return
        }

        do {
            try await Task.sleep(for: Self.legibilityDebounce)
        } catch {
            return
        }

        let input = LegibilityAnalysisInput(
            configuration: document.configuration,
            layerImages: document.backgroundImages
        )
        let warnings = await Task.detached(name: "Label Legibility Analysis", priority: .utility) {
            LabelContrastAnalyzer.analyze(input: input)
        }.value

        if !Task.isCancelled {
            document.legibilityWarnings = warnings
        }
    }

    private func startBuild() {
        document.refreshSourceStates()

        let unfilledSlots = document.items.filter(\.isPlaceholder).map(\.label)
        guard unfilledSlots.isEmpty else {
            buildManager.reportError(
                ValidationError.unfilledPlaceholder(unfilledSlots).localizedDescription
            )
            return
        }

        let missingLabels = document.items
            .filter { document.missingSourceIDs.contains($0.id) }
            .map(\.label)
        guard missingLabels.isEmpty else {
            buildManager.reportError(
                ValidationError.missingSources(missingLabels).localizedDescription
            )
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType("com.apple.disk-image") ?? .data]
        panel.nameFieldStringValue = "\(document.volumeName).dmg"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let assetsDir = try document.extractAssetsToTemporaryDirectory()
            buildManager.build(
                configuration: document.configuration,
                assetsDirectory: assetsDir,
                outputURL: url,
                documentURL: document.fileURL
            )
        } catch {
            buildManager.reportError(error.localizedDescription)
        }
    }
}
