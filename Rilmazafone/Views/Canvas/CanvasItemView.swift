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
    @Environment(\.colorScheme) private var colorScheme

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
    private var isLabelIllegible: Bool {
        document.isLabelIllegible(item.id)
    }

    /// The label color Finder will actually draw.
    ///
    /// A window with any custom background keeps its Light Mode rendering, so the label
    /// stays dark however the chrome is drawn — which is why the canvas appearance
    /// toggle moves the title bar and leaves this alone. Only a volume with no custom
    /// background at all gets Finder's adaptive label color, and the toggle previews
    /// that honestly.
    private var labelColor: Color {
        if document.configuration.finderPinsLabelColor {
            return .black
        }
        return colorScheme == .dark ? .white : .black
    }

    private static let missingBadgeSize: CGFloat = 22
    private static let missingBadgeMinimumSize: CGFloat = 12

    var body: some View {
        VStack(spacing: ItemGeometry.textGap * zoom) {
            iconImage
                .frame(width: displayIconSize, height: displayIconSize)
                .overlay(alignment: .bottomTrailing) {
                    // Missing source wins the badge slot: it blocks the build, while
                    // a legibility warning is advisory — and relinking may change the
                    // label anyway, so legibility is re-judged after the fix.
                    if isSourceMissing {
                        missingSourceBadge
                    } else if isLabelIllegible {
                        legibilityBadge
                    }
                }
                .padding(ItemGeometry.iconCellPadding * zoom)

            Text(displayLabel)
                .font(.system(size: textSize * zoom))
                .foregroundStyle(labelColor)
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
            y: isDragging ? 4 : 0,
        )
        .position(
            x: item.position.x * zoom + dragOffset.width,
            y: item.position.y * zoom + dragOffset.height,
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

    // MARK: - Label Legibility

    private static let legibilityBadgeTextSize: CGFloat = 11
    private static let legibilityBadgeMinimumTextSize: CGFloat = 8
    private static let legibilityBadgePadding: CGFloat = 4

    /// Advisory badge for a label the contrast analysis flagged, visually distinct
    /// from the missing-source triangle (orange capsule, text glyph).
    private var legibilityBadge: some View {
        Image(systemName: "textformat.abc")
            .font(.system(
                size: max(Self.legibilityBadgeTextSize * zoom, Self.legibilityBadgeMinimumTextSize),
                weight: .bold,
            ))
            .foregroundStyle(.white)
            .padding(max(Self.legibilityBadgePadding * zoom, 2))
            .background(Capsule().fill(.orange))
            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
            .help(legibilityHelpText)
            .accessibilityLabel(legibilityHelpText)
    }

    private var legibilityHelpText: String {
        "Label may be hard to read against the background. "
            + "Add a panel behind it, move it, or adjust the background."
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
        } else if item.isPlaceholder {
            placeholderTile
        } else {
            genericIcon
        }
    }

    /// Dashed-outline tile shown for an unfilled placeholder slot that has no
    /// harvested icon: signals "drop your item here" with a kind-appropriate
    /// glyph (app, folder, or file) and no warning badge.
    private var placeholderTile: some View {
        RoundedRectangle(cornerRadius: displayIconSize * 0.2, style: .continuous)
            .strokeBorder(
                Color.secondary.opacity(0.6),
                style: StrokeStyle(
                    lineWidth: max(2 * zoom, 1),
                    dash: [6 * zoom, 4 * zoom],
                ),
            )
            .overlay {
                Image(systemName: item.placeholderGlyphName)
                    .resizable()
                    .scaledToFit()
                    .padding(displayIconSize * 0.26)
                    .foregroundStyle(.tertiary)
            }
            .accessibilityLabel(placeholderAccessibilityLabel)
    }

    private var placeholderAccessibilityLabel: String {
        switch item.kind {
        case .folder: "Folder placeholder, drop a folder to fill"
        case .file: "File placeholder, drop a file to fill"
        default: "App placeholder, drop an app to fill"
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
                    height: (snapped.y - item.position.y) * zoom,
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
