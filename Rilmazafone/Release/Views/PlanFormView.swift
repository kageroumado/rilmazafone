#if !APPSTORE
    import AppKit
    import SwiftUI
    import UniformTypeIdentifiers

    // MARK: - Run Setup

    /// Per-run state — everything the next Build/Publish needs that is NOT
    /// part of the plan file: release notes (they differ per build), the
    /// notarization mode, an explicit version, archive reuse. Owned by the
    /// plan window, edited in the Run tab, consumed by the toolbar actions.
    @Observable
    @MainActor
    final class RunSetup {
        var releaseNotes = ""
        var notesError: String?
        var notarization: NotarizationMode = .wait
        var republish = false
        var versionOverride = ""
        var useExistingArchive = false
        var didPrefillNotes = false
    }

    // MARK: - Plan Inspector

    /// The plan's configuration, in the canvas editor's inspector idiom:
    /// three tabs (Project, Publish, Run) kept alive behind a ZStack so tab
    /// switches don't rebuild the grouped Forms.
    ///
    /// Two modes:
    /// - **Executing** (opened an existing plan): values render as static
    ///   text — the plan is a recipe being run, not edited. Only the per-run
    ///   Run tab stays interactive.
    /// - **Editing** (new plan, or Edit Plan toggled on): everything is live.
    struct PlanInspectorView: View {
        @Environment(ReleasePlanDocument.self) private var document
        @Environment(RunSetup.self) private var runSetup
        @Environment(\.undoManager) private var undoManager

        @Binding var tab: PlanInspectorTab
        let isEditing: Bool

        var body: some View {
            ZStack {
                projectTab
                    .opacity(tab == .project ? 1 : 0)
                    .disabled(tab != .project)
                    .accessibilityHidden(tab != .project)

                publishTab
                    .opacity(tab == .publish ? 1 : 0)
                    .disabled(tab != .publish)
                    .accessibilityHidden(tab != .publish)

                runTab
                    .opacity(tab == .run ? 1 : 0)
                    .disabled(tab != .run)
                    .accessibilityHidden(tab != .run)
            }
        }

        // MARK: - Project Tab

        private var projectTab: some View {
            Form {
                projectSection
                signingSection
                artifactsSection
                designSection
            }
            .formStyle(.grouped)
        }

        @ViewBuilder
        private var projectSection: some View {
            Section("Project") {
                if isEditing {
                    LabeledContent("Repository") {
                        HStack(spacing: 6) {
                            Text(repoRootDisplay)
                                .foregroundStyle(.secondary)
                                .truncationMode(.middle)
                                .lineLimit(1)
                            Menu("Change") {
                                Button("Choose Folder\u{2026}") { chooseRepoRoot() }
                                Button("Use Plan's Folder") { resetRepoRoot() }
                                    .disabled(document.plan.project.path == nil)
                            }
                            .fixedSize()
                        }
                    }
                    .help("The app's repo. \u{201C}Plan's folder\u{201D} means the plan lives in the repo root — the default.")

                    Picker("Scheme", selection: schemeBinding) {
                        if document.detection.schemes.isEmpty {
                            Text(document.plan.project.scheme ?? "\u{2014}")
                                .tag(document.plan.project.scheme ?? "")
                        } else {
                            ForEach(document.detection.schemes, id: \.self) { scheme in
                                Text(scheme).tag(scheme)
                            }
                        }
                    }
                    .help("Detected from the Xcode project")
                } else {
                    staticRow("Repository", repoRootDisplay)
                    staticRow("Scheme", document.plan.project.scheme ?? "\u{2014}")
                }

                versionRow

                if isEditing {
                    Picker("Bump", selection: bumpBinding) {
                        ForEach(ReleasePlan.BumpPolicy.allCases, id: \.self) { policy in
                            Text(policy.label).tag(policy)
                        }
                    }
                    .help("How the next version is derived; an explicit version in the Run tab overrides it")
                }
            }
        }

        /// Shows what the next build will actually do: current → next.
        @ViewBuilder
        private var versionRow: some View {
            LabeledContent("Version") {
                if let version = document.detection.projectVersion {
                    (Text("\(version.marketing) (\(version.build))")
                        + Text(" \u{2192} ").foregroundStyle(.tertiary)
                        + Text("\(nextVersionPreview) (\(version.build + 1))").bold())
                        .monospacedDigit()
                } else {
                    Text("\u{2014}")
                }
            }
            .help("What the next build ships: current \u{2192} next")
        }

        private var nextVersionPreview: String {
            if !runSetup.versionOverride.isEmpty { return runSetup.versionOverride }
            guard let current = document.detection.projectVersion else { return "?" }
            return PlanAutoDetection.bumped(current.marketing, policy: document.plan.versioning.bump)
        }

        @ViewBuilder
        private var signingSection: some View {
            Section("Signing & Notarization") {
                if isEditing {
                    Picker("Identity", selection: identityBinding) {
                        Text("Automatic (Developer ID)").tag("")
                        ForEach(document.detection.identities, id: \.self) { identity in
                            Text(identity).tag(identity)
                        }
                    }
                    .help("Detected from the keychain. Automatic picks the Developer ID Application certificate — the one notarization requires.")
                } else {
                    staticRow("Identity", document.plan.signing.identity ?? "Automatic (Developer ID)")
                }

                HStack(spacing: 6) {
                    if isEditing {
                        TextField(
                            "Notary profile",
                            text: planBinding("Change Notary Profile", \.notarization.keychainProfile),
                            prompt: Text("profile name"),
                        )
                    } else {
                        staticRow(
                            "Notary profile",
                            document.plan.notarization.keychainProfile.isEmpty
                                ? "not set" : document.plan.notarization.keychainProfile,
                        )
                    }
                    if let verified = document.detection.notaryProfileVerified {
                        Image(systemName: verified ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(verified ? .green : .red)
                            .help(verified ? "Profile found in the keychain" : "notarytool can't use this profile — see the info button")
                    }
                    InfoPopoverButton(
                        title: "Notary profile",
                        text: "Notarization uploads each build to Apple for a malware scan; "
                            + "Gatekeeper only opens apps that pass. The profile stores your "
                            + "App Store Connect credentials in the keychain under a name, "
                            + "created once in Terminal:",
                        command: "xcrun notarytool store-credentials <name> --apple-id you@example.com --team-id TEAMID --password <app-specific password>",
                        footnote: "Get an app-specific password at appleid.apple.com, or use an App Store Connect API key instead.",
                    )
                }
            }
        }

        @ViewBuilder
        private var artifactsSection: some View {
            Section("Artifacts") {
                HStack(spacing: 6) {
                    if isEditing {
                        Toggle("App zip", isOn: planBinding("Toggle App Zip", \.artifacts.appZip))
                    } else {
                        staticRow("App zip", document.plan.artifacts.appZip ? "on" : "off")
                    }
                    InfoPopoverButton(
                        title: "App zip",
                        text: "Also produces a zip of the bare signed app next to the DMG. "
                            + "Update frameworks like Sparkle feed on a zip; skip it if the "
                            + "DMG is your only download.",
                    )
                }

                LabeledContent("Output") {
                    HStack(spacing: 6) {
                        Text(outputDirDisplayPath)
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                            .lineLimit(1)
                            .help(resolvedOutputDir?.path ?? "")
                        Button {
                            revealOutputDir()
                        } label: {
                            Image(systemName: "arrow.right.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Show in Finder")
                        if isEditing {
                            Button("Choose\u{2026}") { chooseOutputDir() }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }

        @ViewBuilder
        private var designSection: some View {
            Section("Design") {
                VStack(alignment: .leading, spacing: 8) {
                    designThumbnail
                        .frame(maxWidth: .infinity)
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Design.dmgtemplate")
                                .font(.callout.weight(.medium))
                            Text("Embedded DMG layout")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if document.embeddedDesignURL != nil {
                            Button("Open in Canvas") { openDesign() }
                                .controlSize(.small)
                        } else {
                            Text("save the plan first")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }

        @ViewBuilder
        private var designThumbnail: some View {
            if let preview = document.designPreview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.separator, lineWidth: 1),
                    )
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(height: 100)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }

        // MARK: - Publish Tab

        private var publishTab: some View {
            Form {
                Section("Publish") {
                    if isEditing {
                        Picker(
                            "Channel",
                            selection: planBinding("Change Publish Channel", \.publish.channel),
                        ) {
                            ForEach(ReleasePlan.PublishChannel.allCases, id: \.self) { channel in
                                Text(channel.label).tag(channel)
                            }
                        }
                    } else {
                        staticRow("Channel", document.plan.publish.channel.label)
                    }

                    switch document.plan.publish.channel {
                    case .github:
                        if isEditing {
                            TextField(
                                "Repository",
                                text: optionalPlanBinding("Change Repository", \.publish.githubRepo),
                                prompt: Text("owner/repo"),
                            )
                            .help(repoProvenanceHelp)
                        } else {
                            staticRow("Repository", document.plan.publish.githubRepo ?? "\u{2014}")
                        }
                        githubStatusRow

                        HStack(spacing: 6) {
                            if isEditing {
                                TextField(
                                    "Homebrew tap",
                                    text: optionalPlanBinding("Change Homebrew Tap", \.publish.homebrewTapDir),
                                    prompt: Text("tap checkout (optional)"),
                                )
                            } else {
                                staticRow("Homebrew tap", document.plan.publish.homebrewTapDir ?? "none")
                            }
                            InfoPopoverButton(
                                title: "Homebrew cask",
                                text: "If you maintain your own tap (a homebrew-<name> repo of "
                                    + "casks), point this at its local checkout and each release "
                                    + "rewrites the cask's version and sha256, commits, and "
                                    + "pushes. Apps in the official homebrew/cask repo don't "
                                    + "need this — BrewTestBot picks new GitHub releases up "
                                    + "automatically.",
                            )
                        }

                        notesFileRow
                        postScriptRow
                    case .script:
                        if isEditing {
                            TextField(
                                "Script",
                                text: optionalPlanBinding("Change Publish Script", \.publish.script),
                                prompt: Text("path relative to repo root"),
                            )
                            .help("Runs after the build with RILMAZAFONE_* environment variables describing the artifacts")
                        } else {
                            staticRow("Script", document.plan.publish.script ?? "\u{2014}")
                        }
                        notesFileRow
                        postScriptRow
                    case .none:
                        Text("Build only — artifacts land in the output folder and the version bump stays uncommitted for your own release flow.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }

        private var repoProvenanceHelp: String {
            if let detected = document.detection.githubRepo,
               detected == document.plan.publish.githubRepo {
                "Detected from this repo's origin remote"
            } else {
                "The github.com repository releases are created on, as owner/repo"
            }
        }

        /// One line of truth for what the GitHub channel needs: the gh CLI,
        /// a signed-in account, and push access.
        @ViewBuilder
        private var githubStatusRow: some View {
            let cli = document.detection.githubCLI
            if !document.detection.didRun {
                EmptyView()
            } else if !cli.installed {
                statusLine(
                    ok: false,
                    "Publishing needs the GitHub CLI — install it with:  brew install gh",
                )
            } else if !cli.authenticated {
                statusLine(
                    ok: false,
                    "GitHub CLI isn't signed in — run  gh auth login  in Terminal",
                )
            } else if document.detection.repoVerified == false {
                statusLine(
                    ok: false,
                    "No push access to \(document.plan.publish.githubRepo ?? "the repository") with the signed-in account",
                )
            } else if document.detection.repoVerified == true {
                statusLine(ok: true, "Signed in, push access verified")
            }
        }

        private func statusLine(ok: Bool, _ text: String) -> some View {
            Label {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .yellow)
            }
        }

        @ViewBuilder
        private var postScriptRow: some View {
            HStack(spacing: 6) {
                if isEditing {
                    TextField(
                        "Post script",
                        text: optionalPlanBinding("Change Post Script", \.publish.postScript),
                        prompt: Text("optional"),
                    )
                } else if let script = document.plan.publish.postScript {
                    staticRow("Post script", script)
                }
                if isEditing || document.plan.publish.postScript != nil {
                    InfoPopoverButton(
                        title: "Post script",
                        text: "An executable (repo-relative or absolute) run after "
                            + "distribution as the final publish stage — for app-specific "
                            + "tails like CDN purges or notifications. It receives "
                            + "RILMAZAFONE_APP, _VERSION, _BUILD, _DMG, _ARTIFACTS, "
                            + "_RELEASE_URL, _NOTES, and _REPO_ROOT; a non-zero exit "
                            + "fails the stage.",
                    )
                }
            }
        }

        @ViewBuilder
        private var notesFileRow: some View {
            if isEditing {
                LabeledContent("Notes file") {
                    HStack(spacing: 6) {
                        Text(document.plan.publish.notesFile ?? "none")
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                            .lineLimit(1)
                        Menu("Change") {
                            Button("Choose File\u{2026}") { chooseNotesFile() }
                            Button("None") {
                                document.updatePlan("Clear Notes File", undoManager: undoManager) {
                                    $0.publish.notesFile = nil
                                }
                            }
                            .disabled(document.plan.publish.notesFile == nil)
                        }
                        .fixedSize()
                    }
                }
                .help("A changelog file that prefills the release notes each time. Paths are stored relative to the repo when possible.")
            } else if let notesFile = document.plan.publish.notesFile {
                staticRow("Notes file", notesFile)
            }
        }

        // MARK: - Run Tab

        private var runTab: some View {
            Form {
                notesSection
                runOptionsSection
            }
            .formStyle(.grouped)
        }

        /// Per-run, never stored in the plan — changelogs differ per build.
        @ViewBuilder
        private var notesSection: some View {
            if document.plan.publish.channel != .none {
                Section {
                    @Bindable var runSetup = runSetup
                    TextEditor(text: $runSetup.releaseNotes)
                        .font(.body)
                        .frame(minHeight: 88)
                    if let error = runSetup.notesError {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Release notes")
                } footer: {
                    if document.plan.publish.notesFile != nil {
                        Text("Prefilled from \(document.plan.publish.notesFile ?? ""); edits here apply to this release only.")
                    } else {
                        Text("Shown on the release. Written fresh for each version.")
                    }
                }
            }
        }

        @ViewBuilder
        private var runOptionsSection: some View {
            Section("Next run") {
                @Bindable var runSetup = runSetup

                TextField(
                    "Version",
                    text: $runSetup.versionOverride,
                    prompt: Text("auto — \(nextVersionPreview)"),
                )
                .help("Leave empty to apply the bump policy")

                Picker("Notarization", selection: $runSetup.notarization) {
                    ForEach(NotarizationMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .help("Waiting takes a few minutes. \u{201C}Submit, staple later\u{201D} returns immediately; finish with the Staple button once Apple accepts. Skipping means Gatekeeper blocks the app on other Macs.")

                if let archive = document.detection.latestArchive {
                    Toggle(isOn: $runSetup.useExistingArchive) {
                        Text("Reuse Xcode archive")
                        Text(archive.displayLine)
                    }
                    .help("Skips archiving and signs the archive Xcode Organizer already has, like distributing from Organizer")
                }

                if document.detection.projectVersion != nil {
                    Toggle(isOn: $runSetup.republish) {
                        Text("Republish current version")
                        Text("No version bump; replaces the assets on the existing release")
                    }
                }
            }
        }

        // MARK: - Helpers

        private func staticRow(_ label: String, _ value: String) -> some View {
            LabeledContent(label) {
                Text(value)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }

        private var repoRootDisplay: String {
            document.plan.project.path ?? "Plan's folder"
        }

        private var resolvedOutputDir: URL? {
            guard let planURL = document.fileURL,
                  let resolved = try? document.plan.resolve(planURL: planURL)
            else { return nil }
            return resolved.outputDirURL
        }

        private var outputDirDisplayPath: String {
            guard let url = resolvedOutputDir else {
                return document.plan.artifacts.outputDir ?? "Application Support"
            }
            return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }

        // MARK: - Bindings

        private func planBinding<Value>(
            _ actionName: String,
            _ keyPath: WritableKeyPath<ReleasePlan, Value>,
        ) -> Binding<Value> {
            Binding(
                get: { document.plan[keyPath: keyPath] },
                set: { newValue in
                    document.updatePlan(actionName, undoManager: undoManager) { plan in
                        plan[keyPath: keyPath] = newValue
                    }
                },
            )
        }

        /// Empty string ↔ nil, so cleared fields fall back to auto-detection.
        private func optionalPlanBinding(
            _ actionName: String,
            _ keyPath: WritableKeyPath<ReleasePlan, String?>,
        ) -> Binding<String> {
            Binding(
                get: { document.plan[keyPath: keyPath] ?? "" },
                set: { newValue in
                    document.updatePlan(actionName, undoManager: undoManager) { plan in
                        plan[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
                    }
                },
            )
        }

        private var schemeBinding: Binding<String> {
            Binding(
                get: {
                    document.plan.project.scheme ?? document.detection.schemes.first ?? ""
                },
                set: { newValue in
                    document.updatePlan("Change Scheme", undoManager: undoManager) { plan in
                        plan.project.scheme = newValue.isEmpty ? nil : newValue
                    }
                },
            )
        }

        private var identityBinding: Binding<String> {
            Binding(
                get: { document.plan.signing.identity ?? "" },
                set: { newValue in
                    document.updatePlan("Change Signing Identity", undoManager: undoManager) { plan in
                        plan.signing.identity = newValue.isEmpty ? nil : newValue
                    }
                },
            )
        }

        private var bumpBinding: Binding<ReleasePlan.BumpPolicy> {
            planBinding("Change Bump Policy", \.versioning.bump)
        }

        // MARK: - Actions

        private func chooseRepoRoot() {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Use as Repo Root"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            document.updatePlan("Change Repository Root", undoManager: undoManager) { plan in
                plan.project.path = url.path
            }
            redetect()
        }

        private func resetRepoRoot() {
            document.updatePlan("Use Plan's Folder", undoManager: undoManager) { plan in
                plan.project.path = nil
            }
            redetect()
        }

        private func chooseOutputDir() {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Use as Output"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            document.updatePlan("Change Output Folder", undoManager: undoManager) { plan in
                plan.artifacts.outputDir = url.path
            }
        }

        private func revealOutputDir() {
            guard let url = resolvedOutputDir else { return }
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }

        private func chooseNotesFile() {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [.plainText, .text]
            panel.prompt = "Use for Notes"
            guard panel.runModal() == .OK, let url = panel.url else { return }

            // Store repo-relative when the file lives inside the repo, so the
            // plan stays portable across machines.
            var stored = url.path
            if let planURL = document.fileURL,
               let resolved = try? document.plan.resolve(planURL: planURL) {
                let repoPath = resolved.repoRoot.path.hasSuffix("/")
                    ? resolved.repoRoot.path : resolved.repoRoot.path + "/"
                if url.path.hasPrefix(repoPath) {
                    stored = String(url.path.dropFirst(repoPath.count))
                }
            }
            document.updatePlan("Change Notes File", undoManager: undoManager) { plan in
                plan.publish.notesFile = stored
            }
        }

        private func openDesign() {
            guard let designURL = document.embeddedDesignURL else { return }
            NSDocumentController.shared.openDocument(
                withContentsOf: designURL, display: true,
            ) { _, _, error in
                if let error {
                    NSAlert(error: error).runModal()
                }
            }
        }

        private func redetect() {
            Task {
                await document.performDetection(undoManager: undoManager)
            }
        }
    }

    // MARK: - Info Popover

    /// The little (i) that answers "what is this?" for concepts a first-time
    /// releaser won't know — notary profiles, app zips, taps. Rich enough for
    /// a short explanation plus a copyable command; tooltips stay for
    /// controls that only need one line.
    struct InfoPopoverButton: View {
        let title: String
        let text: String
        var command: String?
        var footnote: String?

        @State private var isPresented = false

        var body: some View {
            Button {
                isPresented.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("About \(title)")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.headline)
                    Text(text)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if let command {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(command)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(6)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            } label: {
                                Image(systemName: "document.on.document")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy command")
                        }
                    }
                    if let footnote {
                        Text(footnote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(width: 340, alignment: .leading)
            }
        }
    }
#endif
