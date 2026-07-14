import AppKit

/// Drives the two user-template creation flows: File → Save as Template…
/// (snapshot the focused document) and Template from DMG… (import a disk
/// image's layout straight into the library). Both prompt for a name, save
/// through ``TemplateRegistry``, and surface the result — a confirmation
/// alert for Save as Template, selection in the chooser for Template from DMG.
@MainActor
final class TemplateSaveCoordinator {
    static let shared = TemplateSaveCoordinator()

    private init() {}

    // MARK: - Save as Template

    /// File → Save as Template…: converts the document's current design to
    /// template form (app items → placeholders), prompts for a name, and
    /// writes it into the user library.
    func saveAsTemplate(_ document: RilmazafoneDocument) {
        let suggestedName = document.fileURL?.deletingPathExtension().lastPathComponent
            ?? document.configuration.volumeName
        guard let name = Self.promptForTemplateName(
            title: "Save as Template",
            informativeText: "The current design is added to your template library. "
                + "The app becomes a placeholder slot that new documents fill by dropping an app in.",
            defaultName: suggestedName,
            confirmTitle: "Save"
        ) else { return }

        let snapshot = document.templateSnapshot()
        do {
            let entry = try TemplateRegistry.shared.saveUserTemplate(
                named: name,
                configuration: snapshot.configuration,
                assets: snapshot.assets
            )
            presentSaveConfirmation(for: entry)
        } catch {
            presentError(error, title: "Couldn\u{2019}t Save Template")
        }
    }

    // MARK: - Template from DMG

    /// Template from DMG…: prompts for a disk image, runs the standard import
    /// (open panel + progress + error UI), converts the result to template
    /// form, prompts for a name, saves it, and shows it selected in the
    /// chooser.
    func createTemplateFromDMG() {
        guard let url = DMGImportCoordinator.shared.promptForDiskImage(
            message: "Choose a disk image to turn into a template.",
            prompt: "Import"
        ) else { return }

        Task(name: "Template from DMG") {
            guard let result = await DMGImportCoordinator.shared.runImport(from: url) else {
                return
            }
            saveTemplate(
                from: result,
                suggestedName: url.deletingPathExtension().lastPathComponent
            )
        }
    }

    /// Names and saves an import result as a user template. The imported app
    /// items are already placeholders; conversion normalizes their labels and
    /// drops the harvested runtime icons (templates carry design assets only).
    private func saveTemplate(from result: DMGImporter.Result, suggestedName: String) {
        guard let name = Self.promptForTemplateName(
            title: "Template from DMG",
            informativeText: "The imported layout is added to your template library. "
                + "The app becomes a placeholder slot that new documents fill by dropping an app in.",
            defaultName: suggestedName,
            confirmTitle: "Save"
        ) else { return }

        do {
            let entry = try TemplateRegistry.shared.saveUserTemplate(
                named: name,
                configuration: TemplateSnapshot.templateConfiguration(from: result.configuration),
                assets: result.assets
            )
            TemplateChooserController.shared.show(selecting: entry)
        } catch {
            presentError(error, title: "Couldn\u{2019}t Save Template")
        }
    }

    // MARK: - Name Prompt

    private enum Layout {
        static let nameFieldWidth: CGFloat = 240
        static let nameFieldHeight: CGFloat = 24
    }

    /// Modal name prompt (alert with a text field). Returns the entered name,
    /// or `nil` on cancel. An effectively empty name falls back to the
    /// registry's sanitized default. Also used by the chooser's Rename action.
    static func promptForTemplateName(
        title: String,
        informativeText: String,
        defaultName: String,
        confirmTitle: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = informativeText

        let field = NSTextField(frame: NSRect(
            x: 0, y: 0, width: Layout.nameFieldWidth, height: Layout.nameFieldHeight
        ))
        field.stringValue = defaultName
        field.placeholderString = "Template Name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    // MARK: - Confirmation & Errors

    private func presentSaveConfirmation(for entry: TemplateEntry) {
        let alert = NSAlert()
        alert.messageText = "Saved \u{201C}\(entry.name)\u{201D} to Your Templates"
        alert.informativeText = "The template is now available from File > New from Template "
            + "and the template chooser."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show in Finder")
        if alert.runModal() == .alertSecondButtonReturn {
            TemplateRegistry.shared.revealInFinder(entry)
        }
    }

    private func presentError(_ error: any Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
