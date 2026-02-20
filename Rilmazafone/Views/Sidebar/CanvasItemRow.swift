import AppKit
import SwiftUI

struct CanvasItemRow: View {
    let item: CanvasItem

    @State private var cachedIcon: NSImage?

    var body: some View {
        Label {
            Text(item.label)
                .lineLimit(1)
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
        .task(id: item.sourcePath) {
            cachedIcon = Self.resolveIcon(for: item)
        }
        .accessibilityLabel("\(item.label), \(item.kind.displayName)")
    }

    private var isSymlink: Bool {
        item.kind != .applicationsSymlink && item.linkType == .symlink
    }

    private static func resolveIcon(for item: CanvasItem) -> NSImage? {
        CanvasItem.resolveIcon(for: item)
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
