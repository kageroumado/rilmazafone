import AppKit
import SwiftUI

struct CanvasItemRow: View {
    let item: CanvasItem

    @Environment(RilmazafoneDocument.self) private var document
    @State private var cachedIcon: NSImage?

    var body: some View {
        Label {
            HStack(spacing: 4) {
                Text(item.label)
                    .lineLimit(1)
                    .foregroundStyle(item.isPlaceholder ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))

                // Missing source wins over the advisory legibility warning,
                // matching the canvas badge rule.
                if isSourceMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .symbolRenderingMode(.multicolor)
                        .help("Source file is missing. Right-click and choose Locate\u{2026} to relink.")
                        .accessibilityLabel("Source file missing")
                } else if isLabelIllegible {
                    Image(systemName: "textformat.abc")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help(legibilityHelpText)
                        .accessibilityLabel(legibilityHelpText)
                }
            }
        } icon: {
            Group {
                if let nsImage = cachedIcon {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: fallbackIconName)
                        .foregroundStyle(fallbackIconColor)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if isSymlink {
                    Image(systemName: "arrowshape.turn.up.right.fill")
                        .font(.system(size: Self.symlinkBadgeSize))
                        .foregroundStyle(.white)
                        .padding(1.5)
                        .background(Circle().fill(.black.opacity(0.6)))
                        .offset(x: -3, y: 3)
                        .help("Written to the DMG as a symbolic link")
                        .accessibilityHidden(true)
                }
            }
        }
        .task(id: item.iconCacheKey(isSourceMissing: isSourceMissing)) {
            cachedIcon = CanvasItem.resolveIcon(for: item, documentURL: document.fileURL)
                ?? document.importedItemIcons[item.id]
        }
        .accessibilityLabel(accessibilityDescription)
    }

    /// The alias badge on the item's icon. macOS puts the floor for legible text at
    /// 10 pt (`accessibility.md`); this sits at that floor rather than the 6 pt it was,
    /// and the link type is spelled out in the row's accessibility label besides, so
    /// nothing depends on reading a badge this size.
    private static let symlinkBadgeSize: CGFloat = 10

    /// Spells out everything the row shows as marks — the kind, whether it is written
    /// as a link, and any warning — since each of those is otherwise carried by a glyph.
    private var accessibilityDescription: String {
        var parts = [item.label, item.kind.displayName]
        if isSymlink {
            parts.append("symbolic link")
        }
        if isSourceMissing {
            parts.append("source file missing")
        } else if isLabelIllegible {
            parts.append("label may be hard to read")
        }
        return parts.joined(separator: ", ")
    }

    private var isSymlink: Bool {
        item.kind != .applicationsSymlink && item.linkType == .symlink
    }

    private var isSourceMissing: Bool {
        document.missingSourceIDs.contains(item.id)
    }

    private var isLabelIllegible: Bool {
        document.isLabelIllegible(item.id)
    }

    private var legibilityHelpText: String {
        "Label may be hard to read against the background. "
            + "Add a panel behind it, move it, or adjust the background."
    }

    private var fallbackIconName: String {
        switch item.kind {
        case .app: "app.dashed"
        case .applicationsSymlink: "folder"
        case .file: "doc"
        case .folder: "folder"
        }
    }

    private var fallbackIconColor: Color {
        if item.isPlaceholder {
            return .secondary
        }
        switch item.kind {
        case .app: return .accentColor
        case .applicationsSymlink, .file: return .secondary
        case .folder: return .blue
        }
    }
}

extension CanvasItemKind {
    var displayName: String {
        switch self {
        case .app: "Application"
        case .applicationsSymlink: "Applications Symlink"
        case .file: "File"
        case .folder: "Folder"
        }
    }
}
