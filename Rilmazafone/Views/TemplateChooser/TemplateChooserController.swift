import AppKit
import os
import SwiftUI

// MARK: - New Document Policy

/// Decides what the New command (⌘N) does, factored into a pure function so
/// the preference round-trip is testable.
nonisolated enum NewDocumentPolicy {
    /// UserDefaults key backing both the chooser's "Don't show this dialog
    /// again" checkbox and the Settings pane's "For New Documents" radio.
    /// `true` (the default when unset) shows the template chooser on ⌘N.
    static let showsChooserDefaultsKey = "ShowTemplateChooserForNewDocuments"

    enum Action: Equatable {
        case showChooser
        case createBlankDocument
    }

    /// Reads the chooser preference, defaulting to showing the chooser.
    static func showsChooser(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsChooserDefaultsKey) as? Bool ?? true
    }

    /// ⌘N follows the preference; ⌥⌘N (`isExplicitChooserRequest`) always
    /// opens the chooser.
    static func action(showsChooser: Bool, isExplicitChooserRequest: Bool) -> Action {
        if isExplicitChooserRequest || showsChooser {
            .showChooser
        } else {
            .createBlankDocument
        }
    }
}

// MARK: - Chooser Selection

/// What the chooser grid has selected: the Blank pseudo-entry or a template.
enum TemplateChooserSelection: Hashable {
    case blank
    case template(TemplateEntry)

    /// The window size the selection carries before any preset override.
    var defaultWindowSize: CGSize {
        switch self {
        case .blank: TemplateRegistry.blankWindowSize
        case let .template(entry): entry.windowSize
        }
    }
}

// MARK: - Chooser Controller

/// Owns the template chooser's auxiliary window and routes creation through
/// the staged-result path (`DMGImportCoordinator.openNewDocument(with:)`) so
/// documents created from templates keep normal untitled/autosave/recents
/// semantics. Also the direct-create target for the File and Dock menus.
@MainActor
final class TemplateChooserController: NSObject, NSWindowDelegate {
    static let shared = TemplateChooserController()

    private static let logger = Logger(
        subsystem: "glass.kagerou.rilmazafone", category: "template-chooser"
    )

    private enum Layout {
        static let windowSize = NSSize(width: 700, height: 480)
    }

    private var window: NSWindow?

    // MARK: Entry Points

    /// ⌘N: opens the chooser or creates a blank document per the preference.
    func newDocument() {
        let action = NewDocumentPolicy.action(
            showsChooser: NewDocumentPolicy.showsChooser(),
            isExplicitChooserRequest: false
        )
        switch action {
        case .showChooser:
            show()
        case .createBlankDocument:
            NSDocumentController.shared.newDocument(nil)
        }
    }

    /// Opens (or brings forward) the chooser window. Logs the open latency —
    /// the acceptance bar is < 200 ms with a warm registry.
    func show() {
        let start = ContinuousClock.now
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = TemplateChooserView(
            registry: .shared,
            onCreate: { [weak self] selection, windowSizeOverride in
                self?.create(selection, windowSizeOverride: windowSizeOverride)
            },
            onCancel: { [weak self] in
                self?.close()
            }
        )

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable]
        window.title = "Choose a Template"
        window.isExcludedFromWindowsMenu = true
        window.isReleasedWhenClosed = false
        window.setContentSize(Layout.windowSize)
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)

        let elapsed = start.duration(to: .now)
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15
            + Double(elapsed.components.seconds) * 1_000
        Self.logger.info("Template chooser opened in \(milliseconds, format: .fixed(precision: 1)) ms")
    }

    /// Creates a document from a template with its own default window size —
    /// the direct path used by File → New from Template and the Dock menu.
    func createDocument(from entry: TemplateEntry, windowSizeOverride: CGSize? = nil) {
        do {
            let result = try TemplateInstantiator.instantiate(
                templateAt: entry.url,
                windowSizeOverride: windowSizeOverride
            )
            DMGImportCoordinator.shared.openNewDocument(with: result)
        } catch {
            presentCreationError(error, templateName: entry.name)
        }
    }

    // MARK: Chooser Actions

    private func create(_ selection: TemplateChooserSelection, windowSizeOverride: CGSize?) {
        close()
        switch selection {
        case .blank:
            if let size = windowSizeOverride {
                DMGImportCoordinator.shared.openNewDocument(
                    with: TemplateInstantiator.blank(windowSize: size)
                )
            } else {
                NSDocumentController.shared.newDocument(nil)
            }
        case let .template(entry):
            createDocument(from: entry, windowSizeOverride: windowSizeOverride)
        }
    }

    private func close() {
        window?.close()
        window = nil
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        window = nil
    }

    // MARK: Errors

    private func presentCreationError(_ error: any Error, templateName: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn\u{2019}t Create Document from \u{201C}\(templateName)\u{201D}"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
