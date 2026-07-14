import AppKit
import UniformTypeIdentifiers

/// Drives the Import DMG flow: open panel, progress presentation, off-main
/// import, and routing the result into a new untitled document.
///
/// `DocumentGroup`'s `newDocument` closure is the only place SwiftUI lets the
/// app construct the document instance, so the coordinator stages the imported
/// result and triggers `NSDocumentController.newDocument(_:)`; the closure
/// consumes the staged result exactly once, keeping untitled semantics,
/// autosave, and recents on the normal document path.
@MainActor
final class DMGImportCoordinator {
    static let shared = DMGImportCoordinator()

    private var pendingResult: DMGImporter.Result?

    private init() {}

    // MARK: - Entry Points

    /// File → Import DMG…: prompts for a disk image and imports its layout
    /// into a new untitled document.
    func presentOpenPanel() {
        guard let url = promptForDiskImage(
            message: "Choose a disk image to import its layout.",
            prompt: "Import",
        ) else { return }
        Task {
            await importIntoNewDocument(from: url)
        }
    }

    /// Runs the standard disk-image open panel and returns the chosen image,
    /// or `nil` on cancel. Shared with the Template from DMG flow.
    func promptForDiskImage(message: String, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.diskImage]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = message
        panel.prompt = prompt

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Imports `url` and opens the result as a new untitled document.
    func importIntoNewDocument(from url: URL) async {
        guard let result = await runImport(from: url) else { return }
        openNewDocument(with: result)
    }

    /// Runs the import off the main actor with a floating progress panel,
    /// presenting failures as an alert. Returns `nil` on failure or
    /// cancellation.
    func runImport(from url: URL) async -> DMGImporter.Result? {
        let progressPanel = presentProgressPanel(for: url)
        defer { progressPanel.close() }

        do {
            return try await Task.detached {
                try await DMGImporter.importLayout(of: url)
            }.value
        } catch is CancellationError {
            return nil
        } catch {
            presentImportError(error, imageName: url.lastPathComponent)
            return nil
        }
    }

    /// Stages an import result and opens a new untitled document to consume it.
    func openNewDocument(with result: DMGImporter.Result) {
        pendingResult = result
        NSDocumentController.shared.newDocument(nil)
    }

    /// Consumes the staged import result, if any. Called by the
    /// `DocumentGroup` `newDocument` closure.
    func takePendingResult() -> DMGImporter.Result? {
        defer { pendingResult = nil }
        return pendingResult
    }

    // MARK: - Progress

    private enum Layout {
        static let panelWidth: CGFloat = 380
        static let panelHeight: CGFloat = 64
        static let padding: CGFloat = 20
        static let spacing: CGFloat = 10
    }

    private func presentProgressPanel(for url: URL) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.panelWidth, height: Layout.panelHeight),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        panel.title = "Import DMG"
        panel.isFloatingPanel = true

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)

        let label = NSTextField(
            labelWithString: "Importing \u{201C}\(url.lastPathComponent)\u{201D}\u{2026}",
        )
        label.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = Layout.spacing
        stack.edgeInsets = NSEdgeInsets(
            top: Layout.padding,
            left: Layout.padding,
            bottom: Layout.padding,
            right: Layout.padding,
        )

        panel.contentView = stack
        panel.center()
        panel.orderFront(nil)
        return panel
    }

    // MARK: - Errors

    private func presentImportError(_ error: any Error, imageName: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn\u{2019}t Import \u{201C}\(imageName)\u{201D}"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
