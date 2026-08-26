#if !APPSTORE
    import AppKit
    @preconcurrency import Combine
    import Observation
    import SwiftUI
    import UniformTypeIdentifiers

    // MARK: - Release Plan Document

    /// The `.releaseplan` document: a package holding `plan.json` plus the
    /// embedded `Design.dmgtemplate`. Same conformance dance as
    /// ``RilmazafoneDocument`` — see the isolation rationale there; the safety
    /// contract is identical (main-thread mutation, background file I/O only in
    /// `init` and `fileWrapper`).
    @Observable
    final class ReleasePlanDocument: ReferenceFileDocument, ObservableObject, @unchecked Sendable {
        @ObservationIgnored let objectWillChange = ObservableObjectPublisher()

        static let designFilename = "Design.dmgtemplate"

        // MARK: - Persisted State

        var plan: ReleasePlan

        /// The embedded design as read from disk. The canvas edits the design
        /// *in place* inside the bundle (it opens as an ordinary
        /// `.dmgtemplate` document), so on save the design is re-read from
        /// disk rather than written from this possibly stale copy — see
        /// `fileWrapper(snapshot:configuration:)`.
        @ObservationIgnored private var designWrapper: FileWrapper?

        // MARK: - Runtime State

        /// Auto-detection results — provenance for the form's badges. Never
        /// persisted.
        var detection = PlanDetection()

        /// Rendered preview of the plan's DMG design. Never persisted.
        var designPreview: NSImage?

        /// The document's on-disk URL, fed in by the hosting view (the
        /// `ReferenceFileDocument` configurations expose none).
        @ObservationIgnored private(set) var fileURL: URL?

        // MARK: - UTType

        nonisolated static let readableContentTypes: [UTType] = [.rilmazafoneReleasePlan]

        // MARK: - Init

        nonisolated init() {
            self.plan = ReleasePlan()
        }

        init(configuration: ReadConfiguration) throws {
            guard let wrappers = configuration.file.fileWrappers else {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard let manifest = wrappers["plan.json"],
                  let data = manifest.regularFileContents
            else {
                throw CocoaError(.fileReadCorruptFile)
            }
            self.plan = try JSONDecoder().decode(ReleasePlan.self, from: data)
            self.designWrapper = wrappers[Self.designFilename]
        }

        // MARK: - Snapshots

        struct Snapshot {
            let plan: ReleasePlan
            let fileURL: URL?
        }

        func snapshot(contentType _: UTType) throws -> Snapshot {
            Snapshot(plan: plan, fileURL: fileURL)
        }

        func fileWrapper(
            snapshot: Snapshot,
            configuration _: WriteConfiguration,
        ) throws -> FileWrapper {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestData = try encoder.encode(snapshot.plan)

            let directory = FileWrapper(directoryWithFileWrappers: [:])
            directory.addRegularFile(withContents: manifestData, preferredFilename: "plan.json")

            if snapshot.plan.design.source == .embedded {
                directory.addFileWrapper(try currentDesignWrapper(documentURL: snapshot.fileURL))
            }
            return directory
        }

        /// The design subtree to write: fresh from disk when the document has
        /// a URL (the canvas may have saved edits there since we read it), the
        /// cached read otherwise, or a scaffold for a brand-new plan.
        private nonisolated func currentDesignWrapper(documentURL: URL?) throws -> FileWrapper {
            if let documentURL {
                let onDisk = documentURL.appending(path: Self.designFilename)
                if FileManager.default.fileExists(atPath: onDisk.path) {
                    let fresh = try FileWrapper(url: onDisk)
                    fresh.preferredFilename = Self.designFilename
                    return fresh
                }
            }
            if let designWrapper {
                let copy = FileWrapper(directoryWithFileWrappers: designWrapper.fileWrappers ?? [:])
                copy.preferredFilename = Self.designFilename
                return copy
            }
            return try Self.scaffoldDesign()
        }

        /// A starter design for a fresh plan: an app placeholder and the
        /// Applications symlink, ready to open in the canvas. Also the seed
        /// `ReleasePlanCreator` uses for chooser-born plans.
        nonisolated static func scaffoldDesign() throws -> FileWrapper {
            var design = DMGConfiguration()
            design.items = [
                CanvasItem.appPlaceholder(position: CGPoint(x: 193, y: 200)),
                CanvasItem(
                    kind: .applicationsSymlink,
                    label: "Applications",
                    position: CGPoint(x: 467, y: 200),
                ),
            ]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(design)

            let directory = FileWrapper(directoryWithFileWrappers: [:])
            directory.preferredFilename = designFilename
            directory.addRegularFile(withContents: data, preferredFilename: "document.json")
            return directory
        }

        // MARK: - URL Tracking

        func documentFileURLDidChange(_ url: URL?) {
            fileURL = url
        }

        /// The embedded design's on-disk URL, once the document has been saved.
        var embeddedDesignURL: URL? {
            fileURL?.appending(path: Self.designFilename)
        }

        // MARK: - Undo-Aware Mutation

        func withUndo(
            _ undoManager: UndoManager?,
            _ actionName: String,
            _ handler: @escaping @MainActor @Sendable (ReleasePlanDocument, UndoManager?) -> Void,
        ) {
            MainActor.assumeIsolated {
                undoManager?.registerUndo(withTarget: self) { doc in
                    MainActor.assumeIsolated {
                        handler(doc, undoManager)
                    }
                }
                undoManager?.setActionName(actionName)
            }
        }

        func setPlan(_ newValue: ReleasePlan, actionName: String, undoManager: UndoManager?) {
            let oldValue = plan
            plan = newValue
            objectWillChange.send()
            withUndo(undoManager, actionName) { doc, um in
                doc.setPlan(oldValue, actionName: actionName, undoManager: um)
            }
        }

        /// One-liner for the form's field bindings.
        func updatePlan(
            _ actionName: String,
            undoManager: UndoManager?,
            _ mutate: (inout ReleasePlan) -> Void,
        ) {
            var updated = plan
            mutate(&updated)
            guard updated != plan else { return }
            setPlan(updated, actionName: actionName, undoManager: undoManager)
        }
    }

    // MARK: - Auto-Detection State

    /// What the auto-fill pass found, kept beside the plan so the form can
    /// label values with their provenance (`auto · git remote`, `edited`).
    nonisolated struct PlanDetection: Equatable {
        var githubRepo: String?
        var repoVerified: Bool?
        var schemes: [String] = []
        var projectVersion: PlanAutoDetection.ProjectVersion?
        var identities: [String] = []
        var notaryProfileVerified: Bool?
        var githubCLI = PlanAutoDetection.GitHubCLIStatus()
        /// Latest Organizer archive of this app, offered for reuse.
        var latestArchive: XcodeArchives.Entry?
        var didRun = false
    }

    extension ReleasePlanDocument {
        /// Runs the auto-fill pass: detect from the project, record provenance,
        /// and fill any plan field the user hasn't set. Called when the plan
        /// window appears and after the project path changes.
        func performDetection(undoManager: UndoManager?) async {
            guard let resolved = try? plan.resolve(planURL: fileURL ?? URL(fileURLWithPath: "/")) else {
                detection.didRun = true
                return
            }

            async let repo = PlanAutoDetection.githubRepo(repoRoot: resolved.repoRoot)
            async let schemes = PlanAutoDetection.schemes(xcodeprojURL: resolved.xcodeprojURL)
            async let cli = PlanAutoDetection.githubCLIStatus()
            let identities = DMGBuilder.listSigningIdentities()
            let version = PlanAutoDetection.projectVersion(pbxprojURL: resolved.pbxprojURL)

            var result = PlanDetection()
            result.githubRepo = await repo
            result.schemes = await schemes
            result.githubCLI = await cli
            result.identities = identities
            result.projectVersion = version
            result.latestArchive = XcodeArchives.latest(appName: resolved.appName)
            result.didRun = true

            if let effectiveRepo = plan.publish.githubRepo ?? result.githubRepo {
                result.repoVerified = await PlanAutoDetection.verifyGitHubRepo(effectiveRepo)
            }
            if !plan.notarization.keychainProfile.isEmpty {
                result.notaryProfileVerified = await PlanAutoDetection.verifyNotaryProfile(
                    plan.notarization.keychainProfile,
                )
            }
            detection = result

            await refreshDesignPreview()

            // Fill blanks only — an edited field is never overwritten.
            updatePlan("Auto-Fill Plan", undoManager: undoManager) { plan in
                if plan.project.scheme == nil, let first = result.schemes.first {
                    plan.project.scheme = first
                }
                if plan.publish.githubRepo == nil, let repo = result.githubRepo {
                    plan.publish.githubRepo = repo
                }
                if plan.signing.identity == nil,
                   let developerID = identities.first(where: { $0.hasPrefix("Developer ID Application") }) {
                    plan.signing.identity = developerID
                }
            }
        }

        /// Loads the design preview: the template's saved `thumbnail.png` when
        /// present, otherwise a live render of its `document.json`.
        func refreshDesignPreview() async {
            guard let planURL = fileURL,
                  let resolved = try? plan.resolve(planURL: planURL)
            else { return }
            let designURL = resolved.designURL

            let savedThumbnail = designURL.appending(path: "thumbnail.png")
            if let image = NSImage(contentsOf: savedThumbnail) {
                designPreview = image
                return
            }

            guard let configuration = try? TemplateInstantiator.configuration(ofTemplateAt: designURL)
            else { return }

            // App items with a live source get their real Finder icon;
            // placeholders draw their own dashed tile in the renderer.
            var itemIcons: [UUID: CGImage] = [:]
            for item in configuration.items {
                guard let path = item.sourcePath,
                      FileManager.default.fileExists(atPath: path)
                else { continue }
                let icon = NSWorkspace.shared.icon(forFile: path)
                if let cgIcon = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    itemIcons[item.id] = cgIcon
                }
            }

            let rendered = await TemplateThumbnailRenderer.render(
                configuration: configuration,
                assetsDirectory: designURL.appending(path: "Assets"),
                itemIcons: itemIcons,
            )
            if let rendered {
                designPreview = NSImage(
                    cgImage: rendered,
                    size: CGSize(
                        width: configuration.window.width,
                        height: configuration.window.height,
                    ),
                )
            }
        }
    }
#endif
