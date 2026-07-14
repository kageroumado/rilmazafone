import AppKit
import SwiftUI

struct CanvasItemView: View, Equatable {
    let item: CanvasItem
    let isSelected: Bool
    let iconSize: CGFloat
    let textSize: CGFloat
    let zoom: CGFloat
    let windowSize: CGSize
    let hideExtensions: Bool
    let onDragChanged: (CGPoint) -> CGPoint
    let onMove: (CGPoint) -> Void
    let onSelect: () -> Void

    nonisolated static func == (lhs: CanvasItemView, rhs: CanvasItemView) -> Bool {
        lhs.item == rhs.item
            && lhs.isSelected == rhs.isSelected
            && lhs.iconSize == rhs.iconSize
            && lhs.textSize == rhs.textSize
            && lhs.zoom == rhs.zoom
            && lhs.windowSize == rhs.windowSize
            && lhs.hideExtensions == rhs.hideExtensions
    }

    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager

    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var cachedIcon: NSImage?

    private var displayIconSize: CGFloat {
        iconSize * zoom
    }
    private var maxLabelWidth: CGFloat {
        (iconSize + 40) * zoom
    }
    private var isSourceMissing: Bool {
        document.missingSourceIDs.contains(item.id)
    }

    /// Finder draws icon in a cell with 10px padding, then text 4px below.
    /// The iloc position is the center of the combined icon cell + text area.
    private static let iconCellPadding: CGFloat = 10
    private static let textGap: CGFloat = 4
    private static let missingBadgeSize: CGFloat = 22
    private static let missingBadgeMinimumSize: CGFloat = 12

    var body: some View {
        VStack(spacing: Self.textGap * zoom) {
            iconImage
                .frame(width: displayIconSize, height: displayIconSize)
                .overlay(alignment: .bottomTrailing) {
                    if isSourceMissing {
                        missingSourceBadge
                    }
                }
                .padding(Self.iconCellPadding * zoom)

            Text(displayLabel)
                .font(.system(size: textSize * zoom))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: maxLabelWidth)
        }
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 4 * zoom)
                    .fill(Color.accentColor.opacity(0.12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4 * zoom)
                            .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 2)
                    }
            }
        }
        .scaleEffect(isDragging ? 0.97 : 1.0)
        .shadow(
            color: .black.opacity(isDragging ? 0.15 : 0),
            radius: isDragging ? 8 : 0,
            y: isDragging ? 4 : 0
        )
        .position(
            x: item.position.x * zoom + dragOffset.width,
            y: item.position.y * zoom + dragOffset.height
        )
        .gesture(dragGesture)
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            if item.requiresSource {
                Button("Locate\u{2026}") {
                    relinkSource()
                }
            }
        }
        .task(id: item.iconCacheKey(isSourceMissing: isSourceMissing)) {
            cachedIcon = CanvasItem.resolveIcon(for: item, documentURL: document.fileURL)
                ?? document.importedItemIcons[item.id]
        }
        .accessibilityLabel("\(item.label), position \(Int(item.position.x)), \(Int(item.position.y))")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Missing Source

    private var missingSourceBadge: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: max(Self.missingBadgeSize * zoom, Self.missingBadgeMinimumSize)))
            .symbolRenderingMode(.multicolor)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            .help("Source file is missing. Right-click and choose Locate\u{2026} to relink.")
            .accessibilityLabel("Source file missing")
    }

    private func relinkSource() {
        guard let url = SourceLocatePanel.present(for: item) else { return }
        Task {
            await document.relinkItem(item.id, to: url, undoManager: undoManager)
        }
    }

    // MARK: - Display Label

    private var displayLabel: String {
        guard hideExtensions else { return item.label }
        let name = item.label as NSString
        let ext = name.pathExtension
        guard !ext.isEmpty else { return item.label }
        return name.deletingPathExtension
    }

    // MARK: - Icon

    @ViewBuilder
    private var iconImage: some View {
        if let nsImage = cachedIcon {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
        } else {
            genericIcon
        }
    }

    @ViewBuilder
    private var genericIcon: some View {
        switch item.kind {
        case .app:
            Image(systemName: "app.dashed")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.blue)

        case .applicationsSymlink:
            Image(systemName: "folder.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.blue)

        case .file:
            Image(systemName: "doc.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)

        case .folder:
            Image(systemName: "folder.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.blue)
        }
    }

    // MARK: - Drag

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    onSelect()
                }
                let rawX = item.position.x + value.translation.width / zoom
                let rawY = item.position.y + value.translation.height / zoom
                let snapped = onDragChanged(CGPoint(x: rawX, y: rawY))
                dragOffset = CGSize(
                    width: (snapped.x - item.position.x) * zoom,
                    height: (snapped.y - item.position.y) * zoom
                )
            }
            .onEnded { value in
                isDragging = false
                let rawX = item.position.x + value.translation.width / zoom
                let rawY = item.position.y + value.translation.height / zoom
                let snapped = onDragChanged(CGPoint(x: rawX, y: rawY))
                dragOffset = .zero
                onMove(snapped)
            }
    }
}
