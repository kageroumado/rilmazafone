#if !APPSTORE
    import AppKit
    import UniformTypeIdentifiers

    // MARK: - Release Plan Creator

    /// Creates `.releaseplan` packages on disk and opens them — the entry
    /// points behind the template chooser's "New Release Plan…" and the
    /// design document's "Save as Release Plan…".
    ///
    /// Plans are saved from birth rather than starting untitled: a plan is
    /// anchored to its location (the default repo root is the folder it lives
    /// in), so auto-detection can only run once the file has a home.
    @MainActor
    enum ReleasePlanCreator {
        /// A fresh plan with a scaffolded blank design.
        static func createNew() {
            guard let url = promptForLocation(defaultName: "Untitled") else { return }
            do {
                let design = try ReleasePlanDocument.scaffoldDesign()
                try write(plan: ReleasePlan(), design: design, to: url)
                open(url)
            } catch {
                presentError(error)
            }
        }

        /// A plan seeded with the given design document's current state —
        /// the "this DMG design is ready, now ship it" conversion.
        static func createFromDesign(_ document: RilmazafoneDocument) {
            let suggestedName = document.fileURL?.deletingPathExtension().lastPathComponent
                ?? document.volumeName
            guard let url = promptForLocation(
                defaultName: suggestedName,
                directory: document.fileURL?.deletingLastPathComponent(),
            ) else { return }
            do {
                let snapshot = try document.snapshot(contentType: .rilmazafoneDocument)
                let design = try RilmazafoneDocument.makeFileWrapper(snapshot: snapshot)
                try write(plan: ReleasePlan(), design: design, to: url)
                open(url)
            } catch {
                presentError(error)
            }
        }

        // MARK: - Pieces

        private static func promptForLocation(
            defaultName: String,
            directory: URL? = nil,
        ) -> URL? {
            let panel = NSSavePanel()
            panel.title = "New Release Plan"
            panel.message = "A release plan lives in the app's repository — its folder is the default repo root."
            panel.allowedContentTypes = [.rilmazafoneReleasePlan]
            panel.nameFieldStringValue = "\(defaultName).releaseplan"
            panel.canCreateDirectories = true
            if let directory {
                panel.directoryURL = directory
            }
            guard panel.runModal() == .OK else { return nil }
            return panel.url
        }

        private static func write(plan: ReleasePlan, design: FileWrapper, to url: URL) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let planData = try encoder.encode(plan)

            let package = FileWrapper(directoryWithFileWrappers: [:])
            package.addRegularFile(withContents: planData, preferredFilename: "plan.json")
            design.preferredFilename = ReleasePlanDocument.designFilename
            package.addFileWrapper(design)

            try package.write(to: url, options: .atomic, originalContentsURL: nil)
        }

        private static func open(_ url: URL) {
            NSDocumentController.shared.openDocument(
                withContentsOf: url, display: true,
            ) { _, _, error in
                if let error {
                    NSAlert(error: error).runModal()
                }
            }
        }

        private static func presentError(_ error: any Error) {
            let alert = NSAlert()
            alert.messageText = "Couldn\u{2019}t Create Release Plan"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
#endif
