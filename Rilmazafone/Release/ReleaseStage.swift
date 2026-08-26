#if !APPSTORE
    import Foundation

    // MARK: - Stages

    /// One step of the release pipeline. The full ordered list for a run is
    /// computed up front (``ReleasePipeline/stagePlan(for:)``) so both the GUI
    /// timeline and the CLI transcript can render the whole pipeline before
    /// anything executes.
    nonisolated struct ReleaseStage: Identifiable, Hashable, Sendable {
        nonisolated enum Phase: String, Sendable, Codable {
            /// Local and repeatable. Every build stage reverts the version bump
            /// on failure; nothing has left the machine.
            case build
            /// World-visible — the point of no return. Publish stages never
            /// revert; failures are fixed forward.
            case publish
        }

        nonisolated enum FailurePolicy: Sendable {
            case revert
            case forwardFix
        }

        nonisolated enum ID: String, Sendable, Codable, CaseIterable {
            case preflight
            case versionBump
            case archive
            case sign
            case notarizeApp
            case buildDMG
            case notarizeDMG
            case verify
            case eddsaSign
            case archiveDSYMs
            case commitPush
            case githubRelease
            case caskBump
            case runScript
            case postScript
        }

        let id: ID
        let phase: Phase
        let title: String

        var failurePolicy: FailurePolicy {
            switch phase {
            case .build: .revert
            case .publish: .forwardFix
            }
        }

        nonisolated static func stage(_ id: ID) -> ReleaseStage {
            switch id {
            case .preflight: ReleaseStage(id: id, phase: .build, title: "Preflight")
            case .versionBump: ReleaseStage(id: id, phase: .build, title: "Version bump")
            case .archive: ReleaseStage(id: id, phase: .build, title: "Archive")
            case .sign: ReleaseStage(id: id, phase: .build, title: "Sign")
            case .notarizeApp: ReleaseStage(id: id, phase: .build, title: "Notarize app")
            case .buildDMG: ReleaseStage(id: id, phase: .build, title: "Build DMG")
            case .notarizeDMG: ReleaseStage(id: id, phase: .build, title: "Notarize DMG")
            case .verify: ReleaseStage(id: id, phase: .build, title: "Verify")
            case .eddsaSign: ReleaseStage(id: id, phase: .build, title: "Sign DMG (EdDSA)")
            case .archiveDSYMs: ReleaseStage(id: id, phase: .build, title: "Archive dSYMs")
            case .commitPush: ReleaseStage(id: id, phase: .publish, title: "Commit + push")
            case .githubRelease: ReleaseStage(id: id, phase: .publish, title: "GitHub release")
            case .caskBump: ReleaseStage(id: id, phase: .publish, title: "Cask bump")
            case .runScript: ReleaseStage(id: id, phase: .publish, title: "Publish script")
            case .postScript: ReleaseStage(id: id, phase: .publish, title: "Post script")
            }
        }
    }

    // MARK: - Events

    nonisolated enum StageOutcome: Sendable {
        case ok(detail: String)
        case skipped(reason: String)
        case failed(message: String)
    }

    /// The event stream a run emits. One stream drives the GUI timeline, the
    /// CLI transcript, and `--json` NDJSON output.
    nonisolated enum StageEvent: Sendable {
        case stageBegan(ReleaseStage.ID)
        /// A human-readable progress line within the current stage.
        case log(ReleaseStage.ID, String)
        case stageEnded(ReleaseStage.ID, StageOutcome, elapsed: Duration)
        case finished(ReleaseSummary)
    }

    // MARK: - Run Requests

    nonisolated enum NotarizationMode: String, Sendable, CaseIterable {
        /// Submit and wait for Apple, then staple.
        case wait
        /// Submit and return; `release staple` (or the GUI) finishes later.
        case async
        /// No notarization — Gatekeeper will block the result on other Macs.
        case skip

        var label: String {
            switch self {
            case .wait: "Notarize and wait"
            case .async: "Submit, staple later"
            case .skip: "Skip notarization"
            }
        }
    }

    /// Everything a single run needs beyond the plan itself.
    nonisolated struct ReleaseRunRequest: Sendable {
        var plan: ReleasePlan
        var planURL: URL
        var phases: Set<ReleaseStage.Phase>

        /// Explicit version; `nil` applies the plan's bump policy.
        var versionOverride: String?
        var releaseNotes: String?
        var prerelease: Bool = false
        var notarization: NotarizationMode = .wait
        /// Rebuild/replace the current version: no bump, no commit, and the
        /// GitHub stage clobbers the existing release's assets.
        var republish: Bool = false

        /// Reuse this Xcode Organizer archive instead of archiving fresh —
        /// the Archive stage validates and adopts it.
        var existingArchive: URL?
    }

    // MARK: - Summary

    nonisolated struct ReleaseSummary: Sendable {
        var appName: String
        var version: String
        var build: Int
        var phases: Set<ReleaseStage.Phase>
        var artifacts: [URL]
        var dmgSizeBytes: Int64?
        var releaseURL: String?
        var commitSHA: String?
        var caskStatus: String?
        var notarization: NotarizationMode
        var elapsed: Duration
    }
#endif
