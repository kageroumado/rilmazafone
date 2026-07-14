import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager
    @Binding var selectedItemID: UUID?

    @State private var isFileImporterPresented = false
    @State private var fileImporterKind: FileImporterKind = .app
    @State private var isRenaming = false
    @State private var renamingItemID: UUID?
    @State private var renameText = ""
    @State private var isBackgroundExpanded = true
    @State private var isContentsExpanded = true

    private var hasBackgroundItems: Bool {
        !document.background.layers.isEmpty
            || !document.textLayers.isEmpty
            || !document.sfSymbolLayers.isEmpty
    }

    var body: some View {
        List(selection: $selectedItemID) {
            // Background layers + text layers
            if hasBackgroundItems {
                Section(isExpanded: $isBackgroundExpanded) {
                    ForEach(document.background.layers) { layer in
                        BackgroundLayerRow(layer: layer)
                            .contextMenu {
                                layerContextMenu(for: layer)
                            }
                    }

                    ForEach(document.textLayers) { layer in
                        TextLayerRow(layer: layer)
                            .contextMenu {
                                textLayerContextMenu(for: layer)
                            }
                    }

                    ForEach(document.sfSymbolLayers) { layer in
                        SFSymbolLayerRow(layer: layer)
                            .contextMenu {
                                sfSymbolLayerContextMenu(for: layer)
                            }
                    }
                } header: {
                    Label("Background", systemImage: "photo.stack")
                }
            }

            // Content items
            Section(isExpanded: $isContentsExpanded) {
                ForEach(document.items) { item in
                    CanvasItemRow(item: item)
                        .contextMenu {
                            itemContextMenu(for: item)
                        }
                }
                .onMove { source, destination in
                    document.moveItemInList(
                        from: source,
                        to: destination,
                        undoManager: undoManager,
                    )
                }
                .onDelete { offsets in
                    for index in offsets {
                        let item = document.items[index]
                        document.removeItem(item.id, undoManager: undoManager)
                    }
                }
            } header: {
                Label("Contents", systemImage: "square.grid.2x2")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            sidebarBottomBar
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls: urls)
            return true
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: fileImporterKind.contentTypes,
            allowsMultipleSelection: fileImporterKind == .backgroundImage,
        ) { result in
            handleFileImport(result)
        }
        .alert("Rename Item", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let id = renamingItemID, !renameText.isEmpty {
                    document.setItemLabel(id, to: renameText, undoManager: undoManager)
                }
            }
        } message: {
            Text("Enter a new name for this item.")
        }
    }

    // MARK: - Bottom Bar

    private var sidebarBottomBar: some View {
        HStack(spacing: 4) {
            Menu {
                Button("Add Application\u{2026}") {
                    fileImporterKind = .app
                    isFileImporterPresented = true
                }
                Button("Add Applications Symlink") {
                    addApplicationsSymlink()
                }
                Divider()
                Button("Add File\u{2026}") {
                    fileImporterKind = .file
                    isFileImporterPresented = true
                }
                Divider()
                Button("Add Background Image\u{2026}") {
                    fileImporterKind = .backgroundImage
                    isFileImporterPresented = true
                }
                Button("Add Text Layer") {
                    document.addTextLayer(undoManager: undoManager)
                }
                Button("Add Symbol Layer") {
                    document.addSFSymbolLayer(undoManager: undoManager)
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Add element")

            Button {
                removeSelected()
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .disabled(selectedItemID == nil)
            .accessibilityLabel("Remove selected element")

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Context Menus

    @ViewBuilder
    private func itemContextMenu(for item: CanvasItem) -> some View {
        Button("Rename\u{2026}") {
            renameText = item.label
            renamingItemID = item.id
            isRenaming = true
        }

        if item.requiresSource {
            Button("Locate\u{2026}") {
                if let url = SourceLocatePanel.present(for: item) {
                    Task {
                        await document.relinkItem(item.id, to: url, undoManager: undoManager)
                    }
                }
            }
        }

        if let path = item.sourcePath {
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(
                    path,
                    inFileViewerRootedAtPath: "",
                )
            }
        }

        Divider()

        Button("Delete", role: .destructive) {
            document.removeItem(item.id, undoManager: undoManager)
            if selectedItemID == item.id {
                selectedItemID = nil
            }
        }
    }

    private func layerContextMenu(for layer: BackgroundLayer) -> some View {
        Button("Delete", role: .destructive) {
            document.removeBackgroundLayer(layer.id, undoManager: undoManager)
            if selectedItemID == layer.id {
                selectedItemID = nil
            }
        }
    }

    private func textLayerContextMenu(for layer: TextLayerConfiguration) -> some View {
        Button("Delete", role: .destructive) {
            document.removeTextLayer(layer.id, undoManager: undoManager)
            if selectedItemID == layer.id {
                selectedItemID = nil
            }
        }
    }

    private func sfSymbolLayerContextMenu(for layer: SFSymbolLayerConfiguration) -> some View {
        Button("Delete", role: .destructive) {
            document.removeSFSymbolLayer(layer.id, undoManager: undoManager)
            if selectedItemID == layer.id {
                selectedItemID = nil
            }
        }
    }

    // MARK: - Selection

    private func removeSelected() {
        guard let id = selectedItemID else { return }

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

    // MARK: - Drop Handling

    private func handleDrop(urls: [URL]) {
        Task {
            await document.handleDrop(
                urls: urls,
                defaultPosition: defaultPosition(),
                undoManager: undoManager,
            )
        }
    }

    private func handleFileImport(_ result: Result<[URL], any Error>) {
        guard case let .success(urls) = result else { return }

        switch fileImporterKind {
        case .app:
            if let url = urls.first {
                Task {
                    let width = document.window.width
                    let iconSize = document.iconSize
                    let appX = round((2 * width - iconSize) / 6)
                    let centerY = round(document.window.height / 2)
                    await document.addApp(
                        from: url,
                        at: CGPoint(x: appX, y: centerY),
                        undoManager: undoManager,
                    )
                }
            }
        case .file:
            if let url = urls.first {
                document.addFileItem(from: url, at: defaultPosition(), undoManager: undoManager)
            }
        case .backgroundImage:
            for url in urls {
                try? document.importBackgroundImage(from: url, undoManager: undoManager)
            }
        }
    }

    private func addApplicationsSymlink() {
        let hasSymlink = document.items.contains {
            $0.kind == .applicationsSymlink
        }
        guard !hasSymlink else { return }

        let width = document.window.width
        let height = document.window.height

        let item = CanvasItem(
            kind: .applicationsSymlink,
            label: "Applications",
            position: CGPoint(
                x: width * 2 / 3,
                y: height / 2,
            ),
        )
        document.addItem(item, undoManager: undoManager)
    }

    private func defaultPosition() -> CGPoint {
        CGPoint(
            x: document.window.width / 2,
            y: document.window.height / 2,
        )
    }
}

// MARK: - Background Layer Row

private struct BackgroundLayerRow: View {
    let layer: BackgroundLayer
    @Environment(RilmazafoneDocument.self) private var document

    var body: some View {
        Label {
            Text(layer.label)
                .lineLimit(1)
        } icon: {
            if let image = document.backgroundImages[layer.id] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Text Layer Row

private struct TextLayerRow: View {
    let layer: TextLayerConfiguration

    var body: some View {
        Label {
            Text(layer.text)
                .lineLimit(1)
        } icon: {
            Image(systemName: "textformat")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - SF Symbol Layer Row

private struct SFSymbolLayerRow: View {
    let layer: SFSymbolLayerConfiguration

    var body: some View {
        Label {
            Text(layer.symbolName)
                .lineLimit(1)
        } icon: {
            Image(systemName: layer.symbolName)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - File Importer Kind

private enum FileImporterKind: Equatable {
    case app
    case file
    case backgroundImage

    var contentTypes: [UTType] {
        switch self {
        case .app: [.applicationBundle]
        case .file: [.item]
        case .backgroundImage: [.png, .jpeg, .tiff]
        }
    }
}
