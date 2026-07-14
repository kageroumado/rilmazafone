import AppKit
import UniformTypeIdentifiers

/// Presents an open panel to relink a canvas item to its source on disk,
/// filtered to the item's kind. Returns the chosen URL, or `nil` on cancel.
///
/// Shared by the canvas item context menu, the sidebar row context menu, and
/// the item inspector — Phase 2's DMG import lands its placeholder items on the
/// same relink flow.
@MainActor
enum SourceLocatePanel {
    static func present(for item: CanvasItem) -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Locate \u{201C}\(item.label)\u{201D}"
        panel.prompt = "Relink"
        panel.allowsMultipleSelection = false

        switch item.kind {
        case .app:
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowedContentTypes = [.applicationBundle]
        case .folder:
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
        case .file, .applicationsSymlink:
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
        }

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
