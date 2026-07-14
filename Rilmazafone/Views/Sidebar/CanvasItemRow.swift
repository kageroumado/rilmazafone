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
                } else if !legibilityModes.isEmpty {
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
                        .font(.system(size: 6))
                        .foregroundStyle(.white)
                        .padding(1)
                        .background(Circle().fill(.black.opacity(0.6)))
                        .offset(x: -2, y: 2)
                }
            }
        }
        .task(id: item.iconCacheKey(isSourceMissing: isSourceMissing)) {
            cachedIcon = CanvasItem.resolveIcon(for: item, documentURL: document.fileURL)
                ?? document.importedItemIcons[item.id]
        }
        .accessibilityLabel("\(item.label), \(item.kind.displayName)")
    }

    private var isSymlink: Bool {
        item.kind != .applicationsSymlink && item.linkType == .symlink
    }

    private var isSourceMissing: Bool {
        document.missingSourceIDs.contains(item.id)
    }

    private var legibilityModes: [LabelAppearanceMode] {
        document.legibilityModes(for: item.id)
    }

    private var legibilityHelpText: String {
        let modes = legibilityModes.map(\.displayName).joined(separator: " and ")
        return "Label may be hard to read in \(modes). "
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
        if item.isPlaceholder { return .secondary }
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
