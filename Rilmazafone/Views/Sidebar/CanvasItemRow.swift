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

                if isSourceMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .symbolRenderingMode(.multicolor)
                        .help("Source file is missing. Right-click and choose Locate\u{2026} to relink.")
                        .accessibilityLabel("Source file missing")
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
        }
        .accessibilityLabel("\(item.label), \(item.kind.displayName)")
    }

    private var isSymlink: Bool {
        item.kind != .applicationsSymlink && item.linkType == .symlink
    }

    private var isSourceMissing: Bool {
        document.missingSourceIDs.contains(item.id)
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
        switch item.kind {
        case .app: .accentColor
        case .applicationsSymlink, .file: .secondary
        case .folder: .blue
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
