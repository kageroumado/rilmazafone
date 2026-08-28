#if !APPSTORE
    import Foundation

    // MARK: - Runner Protocol

    /// The engine-facing seam between the release UI and what actually runs.
    /// The live implementation is ``ReleasePipeline``; the debug scenario menu
    /// and previews inject ``ScriptedReleaseRunner`` so every view state can be
    /// exercised without archiving, notarizing, or touching a repo.
    nonisolated protocol ReleaseRunning: Sendable {
        /// Runs the request, emitting events as stages progress. Throws after
        /// emitting the failing stage's `.stageEnded(.failed)`.
        func run(
            _ request: ReleaseRunRequest,
            emit: @escaping @Sendable (StageEvent) async -> Void,
        ) async throws -> ReleaseSummary
    }

    #if DEBUG
        // MARK: - Scripted Runner

        /// Plays a canned event script derived from the request's real stage
        /// plan, with short delays so progress is visible. Simulates any state
        /// the run UI can reach.
        nonisolated struct ScriptedReleaseRunner: ReleaseRunning {
            enum Scenario: String, CaseIterable, Identifiable {
                case buildSuccess
                case buildAndPublish
                case notarizationRejected
                case archiveFailed
                case asyncSubmitted
                case pushRejected

                var id: String { rawValue }

                var title: String {
                    switch self {
                    case .buildSuccess: "Build succeeds"
                    case .buildAndPublish: "Build + publish succeed"
                    case .notarizationRejected: "Notarization rejected"
                    case .archiveFailed: "Archive fails"
                    case .asyncSubmitted: "Async notarize submitted"
                    case .pushRejected: "Push rejected (publish)"
                    }
                }
            }

            let scenario: Scenario
            /// Delay between scripted events; keep short in previews.
            var pace: Duration = .milliseconds(350)

            /// What the slow stages say while they work. Shaped like the output the real
            /// tools produce, so the demo rehearses the interface honestly.
            private static let stageLogs: [ReleaseStage.ID: [String]] = [
                .archive: [
                    "xcodebuild archive -scheme Demo -configuration Release",
                    "Compiling 214 Swift source files",
                    "Archive succeeded",
                ],
                .notarizeApp: [
                    "notarytool submit Demo.app.zip --keychain-profile demo --wait",
                    "id: 4f2a90c1-6b3d-4a19-9f27-a1c4e6b28e91",
                    "status: In Progress",
                    "status: Accepted",
                ],
                .notarizeDMG: [
                    "notarytool submit Demo-1.3.dmg --keychain-profile demo --wait",
                    "status: Accepted",
                    "stapler staple Demo-1.3.dmg",
                ],
            ]

            private static let stageDetails: [ReleaseStage.ID: String] = [
                .preflight: "Xcode · identity · notary profile",
                .versionBump: "1.2 → 1.3 · build 41 → 42",
                .archive: "Release · arm64 · 0 warnings",
                .sign: "3 nested + app · Developer ID",
                .notarizeApp: "Accepted · ticket stapled",
                .buildDMG: "8.4 MB",
                .notarizeDMG: "Accepted · stapled",
                .verify: "codesign · Gatekeeper · 14 binaries",
                .eddsaSign: "dmg.sig",
                .archiveDSYMs: "b42 zip",
                .commitPush: "\u{201C}Bump version to v1.3 (build 42)\u{201D} → origin",
                .githubRelease: "https://github.com/example/app/releases/tag/v1.3",
                .caskBump: "bumped to 1.3",
                .runScript: "publish.sh",
            ]

            func run(
                _ request: ReleaseRunRequest,
                emit: @escaping @Sendable (StageEvent) async -> Void,
            ) async throws -> ReleaseSummary {
                let stages = ReleasePipeline.stagePlan(for: request)
                let failAt: (ReleaseStage.ID, String)? = switch scenario {
                case .notarizationRejected:
                    (.notarizeApp, "Invalid: the signature of the binary is invalid — AdrafinilHelper is not signed with a valid Developer ID")
                case .archiveFailed:
                    (.archive, "Archive failed (2 errors). ContentView.swift:41: error: cannot find 'undefined' in scope")
                case .pushRejected:
                    (.commitPush, "Push failed — aborting before the release so its tag can't land on a stale commit")
                default:
                    nil
                }
                let start = ContinuousClock.now

                for stage in stages {
                    try Task.checkCancellation()
                    await emit(.stageBegan(stage.id))
                    try? await Task.sleep(for: pace)

                    if let (failID, message) = failAt, failID == stage.id {
                        await emit(.stageEnded(stage.id, .failed(message: message), elapsed: pace))
                        throw ReleasePipelineError(message)
                    }

                    // The stages that take real time in a real run stream tool output
                    // while they work. The demo streams plausible lines so the log tail
                    // shows what it shows in earnest — a bare ellipsis reads as a
                    // rendering fault rather than as progress.
                    for line in Self.stageLogs[stage.id] ?? [] {
                        try Task.checkCancellation()
                        await emit(.log(stage.id, line))
                        try? await Task.sleep(for: pace)
                    }

                    let outcome: StageOutcome
                    if stage.id == .notarizeDMG, scenario == .asyncSubmitted {
                        outcome = .ok(detail: "submitted 4f2a90c1-…-8e91 — staple when accepted")
                    } else {
                        outcome = .ok(detail: Self.stageDetails[stage.id] ?? "")
                    }
                    await emit(.stageEnded(stage.id, outcome, elapsed: pace))
                }

                let summary = ReleaseSummary(
                    appName: "Demo",
                    version: "1.3",
                    build: 42,
                    phases: request.phases,
                    artifacts: [URL(fileURLWithPath: "/tmp/Demo-1.3.dmg")],
                    dmgSizeBytes: 8_400_000,
                    releaseURL: request.phases.contains(.publish)
                        ? "https://github.com/example/app/releases/tag/v1.3" : nil,
                    commitSHA: request.phases.contains(.publish) ? "279fd73" : nil,
                    caskStatus: request.phases.contains(.publish) ? "bumped to 1.3" : nil,
                    notarization: scenario == .asyncSubmitted ? .async : request.notarization,
                    elapsed: .now - start,
                )
                await emit(.finished(summary))
                return summary
            }
        }
    #endif
#endif
