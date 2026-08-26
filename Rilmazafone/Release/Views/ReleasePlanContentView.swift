#if !APPSTORE
    import SwiftUI

    // MARK: - Inspector Tabs

    enum PlanInspectorTab: Hashable {
        case project // Project, signing, artifacts, design
        case publish // Channel and its wiring
        case run // Release notes + next-run options
    }

    // MARK: - Focused Actions

    /// Published by the plan window so the Release menu can drive the same
    /// actions as the toolbar (every toolbar item needs a menu command).
    struct ReleasePlanActions {
        var canRun: Bool
        var build: @MainActor () -> Void
        var publish: @MainActor () -> Void
    }

    extension FocusedValues {
        @Entry var releasePlanActions: ReleasePlanActions?
    }

    // MARK: - Plan Window

    /// The `.releaseplan` document window, shaped like the canvas editor:
    /// the pipeline is the content, the configuration lives in a tabbed
    /// inspector on the right, and the actions sit in the inspector toolbar.
    struct ReleasePlanContentView: View {
        @Environment(ReleasePlanDocument.self) private var document
        @Environment(\.undoManager) private var undoManager
        @Environment(\.documentConfiguration) private var documentConfiguration

        @State private var runModel = ReleaseRunModel()
        @State private var runSetup = RunSetup()
        @State private var isInspectorPresented = true
        @State private var inspectorTab: PlanInspectorTab = .project

        /// New plans open editable; existing plans open in execute mode.
        @State private var isEditingPlan = false
        @State private var didResolveInitialMode = false

        /// Injected engine; the debug scenario menu swaps in a scripted runner.
        @State private var runner: any ReleaseRunning = ReleasePipeline()

        var body: some View {
            PipelineView()
                .toolbar { windowToolbar }
                .inspector(isPresented: $isInspectorPresented) {
                    PlanInspectorView(tab: $inspectorTab, isEditing: isEditingPlan)
                        .inspectorColumnWidth(min: 250, ideal: 300, max: 360)
                        .toolbar {
                            PlanInspectorToolbar(
                                tab: $inspectorTab,
                                canRun: canRun,
                                canPublish: canPublish,
                                onBuild: startBuild,
                                onPublish: startPublish,
                            )
                        }
                }
                .environment(runModel)
                .environment(runSetup)
                .focusedSceneValue(\.releasePlanActions, ReleasePlanActions(
                    canRun: canRun,
                    build: startBuild,
                    publish: startPublish,
                ))
                .frame(minWidth: 760, minHeight: 520)
                .onChange(of: documentConfiguration?.fileURL, initial: true) { _, newURL in
                    document.documentFileURLDidChange(newURL)
                    if !didResolveInitialMode {
                        isEditingPlan = newURL == nil
                        didResolveInitialMode = true
                    }
                }
                .task {
                    runModel.refreshBuildRecord(planIdentity: document.plan.identity)
                    await document.performDetection(undoManager: undoManager)
                    prefillNotes()
                }
        }

        private var canRun: Bool {
            document.fileURL != nil && !runModel.isRunning
        }

        private var canPublish: Bool {
            canRun && document.plan.publish.channel != .none
        }

        // MARK: - Window Toolbar

        @ToolbarContentBuilder
        private var windowToolbar: some ToolbarContent {
            #if DEBUG
                ToolbarItem(placement: .navigation) {
                    Menu("Demo", systemImage: "theatermasks") {
                        ForEach(ScriptedReleaseRunner.Scenario.allCases) { scenario in
                            Button(scenario.title) {
                                runDemo(scenario)
                            }
                        }
                        Divider()
                        Button("Use Live Pipeline") {
                            runner = ReleasePipeline()
                        }
                    }
                    .help("Simulate a run without archiving or publishing")
                }
            #endif

            ToolbarItem {
                Toggle(isOn: $isEditingPlan) {
                    Label("Edit Plan", systemImage: "square.and.pencil")
                }
                .help(isEditingPlan
                    ? "Lock the plan back into execute mode"
                    : "Unlock the plan's configuration for editing")
            }
        }

        // MARK: - Actions

        private func startBuild() {
            start(phases: [.build])
        }

        private func startPublish() {
            guard document.plan.publish.channel != .none else { return }

            // Notes are required for a fresh GitHub release; the error shows
            // beside the notes editor, where the fix is.
            if document.plan.publish.channel == .github,
               !runSetup.republish,
               runSetup.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               document.plan.publish.notesFile == nil {
                runSetup.notesError = "Write release notes before publishing."
                inspectorTab = .run
                isInspectorPresented = true
                return
            }
            runSetup.notesError = nil

            let phases: Set<ReleaseStage.Phase> = runModel.hasCurrentBuild
                ? [.publish]
                : [.build, .publish]
            start(phases: phases)
        }

        private func start(phases: Set<ReleaseStage.Phase>) {
            guard let planURL = document.fileURL else { return }
            let notes = runSetup.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            let request = ReleaseRunRequest(
                plan: document.plan,
                planURL: planURL,
                phases: phases,
                versionOverride: runSetup.versionOverride.isEmpty ? nil : runSetup.versionOverride,
                releaseNotes: notes.isEmpty ? nil : notes,
                prerelease: document.plan.publish.prerelease,
                notarization: runSetup.notarization,
                republish: runSetup.republish,
                existingArchive: runSetup.useExistingArchive
                    ? document.detection.latestArchive?.url : nil,
            )
            runModel.start(request: request, runner: runner)
        }

        private func prefillNotes() {
            guard !runSetup.didPrefillNotes,
                  runSetup.releaseNotes.isEmpty,
                  let planURL = document.fileURL,
                  let resolved = try? document.plan.resolve(planURL: planURL),
                  let notesURL = resolved.notesFileURL,
                  let contents = try? String(contentsOf: notesURL, encoding: .utf8)
            else { return }
            runSetup.releaseNotes = contents
            runSetup.didPrefillNotes = true
        }

        #if DEBUG
            private func runDemo(_ scenario: ScriptedReleaseRunner.Scenario) {
                runner = ScriptedReleaseRunner(scenario: scenario)
                guard let planURL = document.fileURL ?? URL(string: "file:///tmp/Demo.releaseplan") else { return }
                let phases: Set<ReleaseStage.Phase> = switch scenario {
                case .buildSuccess, .notarizationRejected, .archiveFailed, .asyncSubmitted:
                    [.build]
                case .buildAndPublish, .pushRejected:
                    [.build, .publish]
                }
                var plan = document.plan
                if phases.contains(.publish), plan.publish.channel == .none {
                    plan.publish.channel = .github
                    plan.publish.githubRepo = "example/app"
                }
                let request = ReleaseRunRequest(
                    plan: plan,
                    planURL: planURL,
                    phases: phases,
                    releaseNotes: "demo",
                    notarization: scenario == .asyncSubmitted ? .async : .wait,
                )
                runModel.start(request: request, runner: runner)
            }
        #endif
    }

    // MARK: - Inspector Toolbar

    /// The tab picker plus the two pipeline actions, mirroring the canvas
    /// editor's inspector toolbar (picker + prominent Create).
    struct PlanInspectorToolbar: ToolbarContent {
        @Binding var tab: PlanInspectorTab
        let canRun: Bool
        let canPublish: Bool
        var onBuild: () -> Void
        var onPublish: () -> Void

        var body: some ToolbarContent {
            ToolbarSpacer(.flexible)

            ToolbarItem {
                Picker("Inspector", selection: $tab) {
                    Label("Project", systemImage: "doc.text")
                        .accessibilityLabel("Project Settings")
                        .tag(PlanInspectorTab.project)
                    Label("Publish", systemImage: "arrow.up.circle")
                        .accessibilityLabel("Publish Settings")
                        .tag(PlanInspectorTab.publish)
                    Label("Run", systemImage: "play.circle")
                        .accessibilityLabel("Run Options")
                        .tag(PlanInspectorTab.run)
                }
                .pickerStyle(.segmented)
                .help("Switch between Project, Publish, and Run settings")
            }

            ToolbarItem {
                Button(action: onBuild) {
                    Label("Build", systemImage: "hammer")
                }
                .disabled(!canRun)
                .help("Build Release: archive, sign, notarize, and verify — artifacts land in the output folder")
            }

            ToolbarItem {
                Button(action: onPublish) {
                    Label("Publish", systemImage: "arrow.up.circle.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPublish)
                .help(canPublish
                    ? "Ship the latest build through the configured channel"
                    : "Set a publish channel to enable publishing")
            }
        }
    }
#endif
