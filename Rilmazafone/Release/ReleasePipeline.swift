#if !APPSTORE
    import CryptoKit
    import Foundation

    // MARK: - Errors

    nonisolated struct ReleasePipelineError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }

        init(_ message: String) {
            self.message = message
        }
    }

    // MARK: - Pipeline

    /// The live release engine: the port of `kagerou publish` into ordered,
    /// typed stages. Build stages revert the version bump on failure; publish
    /// stages are past the point of no return and only fix forward.
    ///
    /// Stateless — all per-run state lives in a `RunContext` owned by `run`.
    /// Shared by the GUI (`ReleaseRunModel`) and the CLI (`CLIReleaseRunner`).
    nonisolated struct ReleasePipeline: ReleaseRunning {
        /// Same lock directory `kagerou publish` uses, so the two publishers
        /// can't archive concurrently during the migration.
        private static let lockDirectory = URL(fileURLWithPath: "/tmp/refrax-build.lock")

        init() {}

        // MARK: - Stage Plan

        /// The ordered stage list for a request, computed before anything runs
        /// so both frontends can render the full timeline up front.
        static func stagePlan(for request: ReleaseRunRequest) -> [ReleaseStage] {
            var ids: [ReleaseStage.ID] = [.preflight]
            if request.phases.contains(.build) {
                ids += [.versionBump, .archive, .sign]
                if request.notarization == .wait { ids.append(.notarizeApp) }
                ids.append(.buildDMG)
                if request.notarization != .skip { ids.append(.notarizeDMG) }
                ids.append(.verify)
                if request.plan.artifacts.eddsaPrivateKey != nil { ids.append(.eddsaSign) }
                if request.plan.artifacts.dsymArchiveDir != nil { ids.append(.archiveDSYMs) }
            }
            if request.phases.contains(.publish) {
                switch request.plan.publish.channel {
                case .github:
                    if !request.republish { ids.append(.commitPush) }
                    ids.append(.githubRelease)
                    if request.plan.publish.homebrewTapDir != nil { ids.append(.caskBump) }
                case .script:
                    if !request.republish { ids.append(.commitPush) }
                    ids.append(.runScript)
                case .none:
                    break
                }
                if request.plan.publish.channel != .none,
                   request.plan.publish.postScript != nil {
                    ids.append(.postScript)
                }
            }
            return ids.map(ReleaseStage.stage)
        }

        // MARK: - Run Context

        /// Mutable state threaded through the stages of a single run. Confined
        /// to the task executing `run`.
        private final class RunContext {
            let request: ReleaseRunRequest
            let resolved: ResolvedReleasePlan

            var version = ""
            var build = 0
            var oldVersion = ""
            var oldBuild = 0
            var oldVersionConstant: String?
            var bumpApplied = false

            var signingIdentity = ""
            var dmgSizeBytes: Int64 = 0
            var artifacts: [URL] = []
            var pendingSubmissionID: String?
            var releaseSHA: String?
            var releaseURL: String?
            var caskStatus: String?
            var lockAcquired = false

            /// Where this run's archive lives — a fresh Organizer-visible
            /// archive, or the existing one the request reuses.
            let archivePath: URL

            var appSource: URL {
                archivePath.appending(path: "Products/Applications/\(resolved.appName).app")
            }

            var workDir: URL {
                resolved.outputDirURL.appending(path: "work")
            }

            var dmgURL: URL {
                resolved.outputDirURL.appending(path: "\(resolved.appName)-\(version).dmg")
            }

            init(request: ReleaseRunRequest, resolved: ResolvedReleasePlan) {
                self.request = request
                self.resolved = resolved
                self.archivePath = request.existingArchive
                    ?? XcodeArchives.newArchiveURL(appName: resolved.appName)
            }
        }

        private typealias Emit = @Sendable (StageEvent) async -> Void

        // MARK: - Run

        func run(
            _ request: ReleaseRunRequest,
            emit: @escaping @Sendable (StageEvent) async -> Void,
        ) async throws -> ReleaseSummary {
            let resolved = try request.plan.resolve(planURL: request.planURL)
            let context = RunContext(request: request, resolved: resolved)
            let stages = Self.stagePlan(for: request)
            let runStart = ContinuousClock.now

            try FileManager.default.createDirectory(
                at: context.workDir, withIntermediateDirectories: true,
            )

            defer {
                if context.lockAcquired { Self.releaseLock() }
            }

            for stage in stages {
                try Task.checkCancellation()
                await emit(.stageBegan(stage.id))
                let stageStart = ContinuousClock.now
                do {
                    let outcome = try await execute(stage.id, context: context, emit: emit)
                    await emit(.stageEnded(stage.id, outcome, elapsed: .now - stageStart))
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    if stage.failurePolicy == .revert, context.bumpApplied {
                        revertVersionBump(context)
                        await emit(.log(stage.id, "Version numbers reverted to \(context.oldVersion) (\(context.oldBuild))"))
                    }
                    await emit(.stageEnded(stage.id, .failed(message: message), elapsed: .now - stageStart))
                    throw ReleasePipelineError("\(stage.title) failed: \(message)")
                }
            }

            if request.phases.contains(.build) {
                // The archive stays — it lives in Xcode's Organizer store.
                try saveBuildRecord(context)
            } else if context.releaseURL != nil,
                      var record = BuildRecordStore.load(planIdentity: request.plan.identity) {
                record.publishedURL = context.releaseURL
                try? BuildRecordStore.save(record)
            }

            let summary = ReleaseSummary(
                appName: resolved.appName,
                version: context.version,
                build: context.build,
                phases: request.phases,
                artifacts: context.artifacts,
                dmgSizeBytes: context.dmgSizeBytes == 0 ? nil : context.dmgSizeBytes,
                releaseURL: context.releaseURL,
                commitSHA: context.releaseSHA,
                caskStatus: context.caskStatus,
                notarization: request.notarization,
                elapsed: .now - runStart,
            )
            await emit(.finished(summary))
            return summary
        }

        // MARK: - Stage Dispatch

        private func execute(
            _ id: ReleaseStage.ID,
            context: RunContext,
            emit: @escaping Emit,
        ) async throws -> StageOutcome {
            switch id {
            case .preflight: try await preflight(context, emit)
            case .versionBump: try versionBump(context)
            case .archive: try await archive(context, emit)
            case .sign: try await sign(context, emit)
            case .notarizeApp: try await notarizeApp(context, emit)
            case .buildDMG: try await buildDMG(context, emit)
            case .notarizeDMG: try await notarizeDMG(context, emit)
            case .verify: try await verify(context, emit)
            case .eddsaSign: try await eddsaSign(context)
            case .archiveDSYMs: try await archiveDSYMs(context)
            case .commitPush: try await commitPush(context, emit)
            case .githubRelease: try await githubRelease(context, emit)
            case .caskBump: await caskBump(context, emit)
            case .runScript: try await runScript(context, script: context.resolved.plan.publish.script)
            case .postScript: try await runScript(context, script: context.resolved.plan.publish.postScript)
            }
        }

        // MARK: - Preflight

        private func preflight(_ context: RunContext, _ emit: Emit) async throws -> StageOutcome {
            let resolved = context.resolved
            let request = context.request
            var checks: [String] = []

            guard FileManager.default.fileExists(atPath: resolved.pbxprojURL.path) else {
                throw ReleasePipelineError("project.pbxproj not found at \(resolved.pbxprojURL.path)")
            }
            checks.append(resolved.xcodeprojURL.lastPathComponent)

            if request.phases.contains(.build) {
                guard FileManager.default.fileExists(
                    atPath: resolved.designURL.appending(path: "document.json").path,
                ) else {
                    throw ReleasePlanError.designNotFound(resolved.designURL)
                }
                checks.append("design")

                let identity = resolved.plan.signing.identity ?? PlanAutoDetection.developerIDIdentity()
                guard let identity else {
                    throw ReleasePipelineError(
                        "No Developer ID Application identity in the keychain. "
                            + "Set an explicit signing identity in the plan.",
                    )
                }
                context.signingIdentity = identity
                checks.append("identity")

                if request.notarization != .skip {
                    guard !resolved.plan.notarization.keychainProfile.isEmpty else {
                        throw ReleasePipelineError(
                            "No notary keychain profile configured "
                                + "(create one with: xcrun notarytool store-credentials)",
                        )
                    }
                    checks.append("notary profile")
                }
            } else {
                // Publish-only: a current, intact build record is the input.
                guard let record = BuildRecordStore.load(planIdentity: resolved.plan.identity) else {
                    throw ReleasePipelineError("No build record — run a build first.")
                }
                guard record.dmgExists else {
                    throw ReleasePipelineError("Recorded DMG missing at \(record.dmgPath) — rebuild.")
                }
                if record.pendingSubmissionID != nil {
                    throw ReleasePipelineError(
                        "Build #\(record.build) has notarization pending — staple it first.",
                    )
                }
                context.version = record.version
                context.build = record.build
                context.dmgSizeBytes = record.dmgSizeBytes
                context.artifacts = record.artifactURLs
                checks.append("build #\(record.build) (v\(record.version))")
            }

            if request.phases.contains(.publish) {
                switch resolved.plan.publish.channel {
                case .github:
                    guard resolved.plan.publish.githubRepo != nil else {
                        throw ReleasePipelineError("Publish channel is GitHub but no repository is set.")
                    }
                    guard let gh = ExternalTool.find("gh") else {
                        throw ReleasePipelineError("gh CLI not found (brew install gh)")
                    }
                    do {
                        try await ProcessRunner.run(gh, arguments: ["auth", "status"])
                    } catch {
                        throw ReleasePipelineError("gh not authenticated (run: gh auth login)")
                    }
                    if !request.republish,
                       context.request.releaseNotes?.isEmpty != false,
                       resolved.notesFileURL == nil {
                        throw ReleasePipelineError("Release notes required to publish.")
                    }
                    checks.append("gh auth")
                case .script:
                    guard let script = resolved.plan.publish.script,
                          FileManager.default.isExecutableFile(
                              atPath: ReleasePlan.resolve(script, against: resolved.repoRoot).path,
                          )
                    else {
                        throw ReleasePipelineError("Publish channel is Script but no executable script is set.")
                    }
                    checks.append("script")
                case .none:
                    break
                }
            }

            return .ok(detail: checks.joined(separator: " · "))
        }

        // MARK: - Version Bump

        private func versionBump(_ context: RunContext) throws -> StageOutcome {
            let pbxprojURL = context.resolved.pbxprojURL
            let text = try String(contentsOf: pbxprojURL, encoding: .utf8)

            guard let current = PlanAutoDetection.projectVersion(pbxprojURL: pbxprojURL) else {
                throw ReleasePipelineError("No MARKETING_VERSION in \(pbxprojURL.lastPathComponent)")
            }
            context.oldVersion = current.marketing
            context.oldBuild = current.build

            if let constantURL = context.resolved.versionConstantURL,
               let constantText = try? String(contentsOf: constantURL, encoding: .utf8),
               let match = constantText.firstMatch(of: /marketingVersion = "([^"]*)"/) {
                context.oldVersionConstant = String(match.output.1)
            }

            if context.request.republish {
                context.version = current.marketing
                context.build = current.build
                return .ok(detail: "republish — v\(context.version) (\(context.build)) unchanged")
            }

            if let override = context.request.versionOverride {
                guard override.wholeMatch(of: /\d+\.\d+(\.\d+)?/) != nil else {
                    throw ReleasePipelineError("Invalid version format: \(override) (expected X.Y or X.Y.Z)")
                }
                context.version = override
            } else {
                context.version = PlanAutoDetection.bumped(
                    current.marketing, policy: context.resolved.plan.versioning.bump,
                )
            }
            context.build = current.build + 1

            guard var updated = PlanAutoDetection.replacingSetting(
                "MARKETING_VERSION", with: context.version, in: text,
            ) else {
                throw ReleasePipelineError("Could not rewrite MARKETING_VERSION")
            }
            updated = PlanAutoDetection.replacingSetting(
                "CURRENT_PROJECT_VERSION", with: "\(context.build)", in: updated,
            ) ?? updated
            try updated.write(to: pbxprojURL, atomically: true, encoding: .utf8)

            if let constantURL = context.resolved.versionConstantURL,
               let constantText = try? String(contentsOf: constantURL, encoding: .utf8) {
                let rewritten = constantText.replacing(/marketingVersion = "[^"]*"/) { _ in
                    "marketingVersion = \"\(context.version)\""
                }
                try rewritten.write(to: constantURL, atomically: true, encoding: .utf8)
            }

            context.bumpApplied = true
            return .ok(detail: "\(context.oldVersion) → \(context.version) · build \(context.oldBuild) → \(context.build)")
        }

        private func revertVersionBump(_ context: RunContext) {
            let pbxprojURL = context.resolved.pbxprojURL
            if let text = try? String(contentsOf: pbxprojURL, encoding: .utf8) {
                var reverted = PlanAutoDetection.replacingSetting(
                    "MARKETING_VERSION", with: context.oldVersion, in: text,
                ) ?? text
                reverted = PlanAutoDetection.replacingSetting(
                    "CURRENT_PROJECT_VERSION", with: "\(context.oldBuild)", in: reverted,
                ) ?? reverted
                try? reverted.write(to: pbxprojURL, atomically: true, encoding: .utf8)
            }
            if let constantURL = context.resolved.versionConstantURL,
               let oldConstant = context.oldVersionConstant,
               let constantText = try? String(contentsOf: constantURL, encoding: .utf8) {
                let rewritten = constantText.replacing(/marketingVersion = "[^"]*"/) { _ in
                    "marketingVersion = \"\(oldConstant)\""
                }
                try? rewritten.write(to: constantURL, atomically: true, encoding: .utf8)
            }
            context.bumpApplied = false
        }

        // MARK: - Archive

        private func archive(_ context: RunContext, _ emit: Emit) async throws -> StageOutcome {
            // Reusing an Organizer archive: validate it and skip xcodebuild.
            if context.request.existingArchive != nil {
                guard FileManager.default.fileExists(atPath: context.appSource.path) else {
                    throw ReleasePipelineError(
                        "\(context.resolved.appName).app not found in the selected archive",
                    )
                }
                return .ok(detail: "using existing archive: \(context.archivePath.lastPathComponent)")
            }

            try await Self.acquireLock(emit: { await emit(.log(.archive, $0)) })
            context.lockAcquired = true

            let resolved = context.resolved
            try FileManager.default.createDirectory(
                at: context.archivePath.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try? FileManager.default.removeItem(at: context.archivePath)

            await emit(.log(.archive, "Cleaning build products…"))
            _ = try? await ProcessRunner.run(
                ExternalTool.xcodebuild,
                arguments: [
                    "clean",
                    "-project", resolved.xcodeprojURL.path,
                    "-scheme", resolved.scheme,
                    "-configuration", "Release",
                    "-quiet",
                ],
                currentDirectory: resolved.repoRoot,
            )

            let archs = resolved.plan.project.archs.joined(separator: " ")
            await emit(.log(.archive, "Archiving (Release, \(archs))…"))

            // Archive with project defaults (Automatic + Apple Development);
            // restricted entitlements come back at the final main-app re-sign.
            var arguments = [
                "archive",
                "-project", resolved.xcodeprojURL.path,
                "-scheme", resolved.scheme,
                "-configuration", "Release",
                "-archivePath", context.archivePath.path,
                "-allowProvisioningUpdates",
                "ARCHS=\(archs)",
                "ONLY_ACTIVE_ARCH=NO",
                "SWIFT_COMPILATION_MODE=incremental",
            ]
            for (key, value) in resolved.plan.project.extraBuildSettings.sorted(by: { $0.key < $1.key }) {
                arguments.append("\(key)=\(value)")
            }

            let logURL = context.workDir.appending(path: "archive.log")
            do {
                let result = try await ProcessRunner.run(
                    ExternalTool.xcodebuild, arguments: arguments, currentDirectory: resolved.repoRoot,
                )
                try? result.stdout.write(to: logURL)
                let warnings = Self.matchingLines(in: result.stdout, pattern: #"^/.*:\d+:(\d+:)? warning:"#)
                return .ok(detail: "Release · \(archs) · \(warnings.count) warnings")
            } catch let error as ProcessRunner.ProcessError {
                Self.releaseLock()
                context.lockAcquired = false
                try? Data(error.stderr.utf8).write(to: logURL)
                let errors = Self.matchingLines(
                    in: Data(error.stderr.utf8), pattern: #"^/.*:\d+:(\d+:)? error:|^(ld: |clang: error:|Undefined symbols|duplicate symbol)"#,
                )
                for line in errors.prefix(10) {
                    await emit(.log(.archive, line))
                }
                throw ReleasePipelineError(
                    "Archive failed (\(errors.count) errors). Full log: \(logURL.path)",
                )
            }
        }

        private static func matchingLines(in data: Data, pattern: String) -> [String] {
            guard let text = String(data: data, encoding: .utf8),
                  let regex = try? Regex(pattern)
            else { return [] }
            return text.split(separator: "\n").filter { $0.starts(with: regex) }.map(String.init)
        }

        // MARK: - Sign

        private func sign(_ context: RunContext, _ emit: Emit) async throws -> StageOutcome {
            if context.lockAcquired {
                Self.releaseLock()
                context.lockAcquired = false
            }

            let appSource = context.appSource
            guard FileManager.default.fileExists(atPath: appSource.path) else {
                throw ReleasePipelineError("App not found in archive at \(appSource.path)")
            }

            if let profileURL = context.resolved.provisioningProfileURL {
                guard FileManager.default.fileExists(atPath: profileURL.path) else {
                    throw ReleasePipelineError("Provisioning profile not found at \(profileURL.path)")
                }
                let destination = appSource.appending(path: "Contents/embedded.provisionprofile")
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: profileURL, to: destination)
                await emit(.log(.sign, "Embedded: \(profileURL.lastPathComponent)"))
            }

            // Nested code first — a bundle's signature seals what's inside it,
            // so the main app must be signed last. `--deep` signing is
            // deprecated and never used here.
            var signedCount = 0
            let nestedDirectories = [
                "PlugIns", "Extensions", "Helpers", "Frameworks",
                "Library/LaunchAgents", "Library/LaunchDaemons",
            ]
            for directory in nestedDirectories {
                let searchDir = appSource.appending(path: "Contents/\(directory)")
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: searchDir, includingPropertiesForKeys: nil,
                ) else { continue }
                for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    if let profileURL = context.resolved.nestedProvisioningProfileURLs[entry.lastPathComponent] {
                        guard FileManager.default.fileExists(atPath: profileURL.path) else {
                            throw ReleasePipelineError("Nested provisioning profile not found at \(profileURL.path)")
                        }
                        let nestedDestination = entry.appending(path: "Contents/embedded.provisionprofile")
                        try? FileManager.default.removeItem(at: nestedDestination)
                        try FileManager.default.copyItem(at: profileURL, to: nestedDestination)
                        await emit(.log(.sign, "Embedded: \(profileURL.lastPathComponent) → \(entry.lastPathComponent)"))
                    }
                    await emit(.log(.sign, "Signing: \(entry.lastPathComponent)"))
                    try await signBinary(entry, identity: context.signingIdentity)
                    signedCount += 1
                }
            }

            // Bare Mach-O tools directly under Resources (e.g. bundled CLIs).
            let resourcesDir = appSource.appending(path: "Contents/Resources")
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: resourcesDir, includingPropertiesForKeys: [.isRegularFileKey],
            ) {
                for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                    where Self.isMachO(entry) {
                    await emit(.log(.sign, "Signing: \(entry.lastPathComponent) (resource)"))
                    try await signBinary(entry, identity: context.signingIdentity)
                    signedCount += 1
                }
            }

            await emit(.log(.sign, "Signing: \(appSource.lastPathComponent)"))
            if let entitlementsURL = context.resolved.entitlementsURL {
                guard FileManager.default.fileExists(atPath: entitlementsURL.path) else {
                    throw ReleasePipelineError("Entitlements not found at \(entitlementsURL.path)")
                }
                try await ProcessRunner.run(ExternalTool.codesign, arguments: [
                    "--force", "--options", "runtime",
                    "--sign", context.signingIdentity,
                    "--timestamp",
                    "--entitlements", entitlementsURL.path,
                    appSource.path,
                ])
            } else {
                try await signBinary(appSource, identity: context.signingIdentity)
            }

            try await ProcessRunner.run(ExternalTool.codesign, arguments: [
                "--verify", "--deep", "--strict", appSource.path,
            ])

            return .ok(detail: "\(signedCount) nested + \(context.resolved.appName).app · Developer ID")
        }

        private func signBinary(_ url: URL, identity: String) async throws {
            try await ProcessRunner.run(ExternalTool.codesign, arguments: [
                "--force", "--options", "runtime",
                "--sign", identity,
                "--timestamp",
                "--preserve-metadata=entitlements",
                url.path,
            ])
        }

        /// Reads the file's magic number; covers thin and fat Mach-O in both
        /// byte orders.
        static func isMachO(_ url: URL) -> Bool {
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let data = try? handle.read(upToCount: 4),
                  data.count == 4
            else { return false }
            try? handle.close()
            let magic = data.withUnsafeBytes { $0.load(as: UInt32.self) }
            let known: Set<UInt32> = [
                0xFEED_FACE, 0xFEED_FACF, 0xCEFA_EDFE, 0xCFFA_EDFE,
                0xCAFE_BABE, 0xBEBA_FECA,
            ]
            return known.contains(magic)
        }

        // MARK: - Notarization

        private struct NotarySubmission: Decodable {
            let id: String
            let status: String?
        }

        private func notarySubmit(
            _ fileURL: URL,
            profile: String,
            wait: Bool,
        ) async throws -> NotarySubmission {
            var arguments = [
                "notarytool", "submit", fileURL.path,
                "--keychain-profile", profile,
                "--output-format", "json",
            ]
            if wait { arguments += ["--wait", "--timeout", "15m"] }
            let result = try await ProcessRunner.run(ExternalTool.xcrun, arguments: arguments)
            return try JSONDecoder().decode(NotarySubmission.self, from: result.stdout)
        }

        private func notaryFailureDetail(id: String, profile: String) async -> String {
            guard let log = try? await ProcessRunner.runString(
                ExternalTool.xcrun,
                arguments: ["notarytool", "log", id, "--keychain-profile", profile],
            ) else { return "submission \(id)" }
            return log.split(separator: "\n").prefix(20).joined(separator: "\n")
        }

        /// The app is notarized and stapled BEFORE the DMG is built, so the
        /// copy inside the image carries its own ticket and Gatekeeper clears
        /// it even after the user drags it out of the DMG.
        private func notarizeApp(_ context: RunContext, _ emit: Emit) async throws -> StageOutcome {
            let profile = context.resolved.plan.notarization.keychainProfile
            let zipURL = context.workDir.appending(path: "\(context.resolved.appName)-app.zip")
            try? FileManager.default.removeItem(at: zipURL)
            try await ProcessRunner.run(ExternalTool.ditto, arguments: [
                "-c", "-k", "--keepParent", context.appSource.path, zipURL.path,
            ])
            defer { try? FileManager.default.removeItem(at: zipURL) }

            await emit(.log(.notarizeApp, "Submitting app to Apple…"))
            let submission = try await notarySubmit(zipURL, profile: profile, wait: true)
            guard submission.status == "Accepted" else {
                let detail = await notaryFailureDetail(id: submission.id, profile: profile)
                throw ReleasePipelineError("App notarization \(submission.status ?? "failed"):\n\(detail)")
            }

            try await ProcessRunner.run(
                ExternalTool.xcrun, arguments: ["stapler", "staple", context.appSource.path],
            )
            return .ok(detail: "Accepted · ticket stapled")
        }

        private func notarizeDMG(_ context: RunContext, _ emit: Emit) async throws -> StageOutcome {
            let profile = context.resolved.plan.notarization.keychainProfile
            switch context.request.notarization {
            case .skip:
                return .skipped(reason: "notarization skipped")
            case .async:
                let submission = try await notarySubmit(context.dmgURL, profile: profile, wait: false)
                context.pendingSubmissionID = submission.id
                return .ok(detail: "submitted \(submission.id) — staple when accepted")
            case .wait:
                await emit(.log(.notarizeDMG, "Submitting DMG to Apple…"))
                let submission = try await notarySubmit(context.dmgURL, profile: profile, wait: true)
                guard submission.status == "Accepted" else {
                    let detail = await notaryFailureDetail(id: submission.id, profile: profile)
                    throw ReleasePipelineError("DMG notarization \(submission.status ?? "failed"):\n\(detail)")
                }
                try await ProcessRunner.run(
                    ExternalTool.xcrun, arguments: ["stapler", "staple", context.dmgURL.path],
                )
                // Stapling appends the ticket, so the recorded size is re-read.
                context.dmgSizeBytes = Self.fileSize(context.dmgURL)
                return .ok(detail: "Accepted · stapled")
            }
        }

        // MARK: - Build DMG

        private func buildDMG(_ context: RunContext, _ emit: Emit) async throws -> StageOutcome {
            let resolved = context.resolved
            var (configuration, assetsDirectory) = try CLIBuildRunner.loadTemplate(at: resolved.designURL)
            defer { try? FileManager.default.removeItem(at: assetsDirectory) }

            // The design's app item points at the freshly signed archive
            // product — never /Applications, so a stale installed copy can't
            // ship (the bug that bit rilmazafone 1.1).
            for index in configuration.items.indices where configuration.items[index].kind == .app {
                configuration.items[index].sourcePath = context.appSource.path
                configuration.items[index].assetName = nil
                configuration.items[index].isPlaceholder = false
                configuration.items[index].label = "\(resolved.appName).app"
            }
            // The pipeline notarizes the finished DMG itself; a codesign pass
            // on the image would be redundant here.
            configuration.codeSign.enabled = false

            try FileManager.default.createDirectory(
                at: resolved.outputDirURL, withIntermediateDirectories: true,
            )
            try? FileManager.default.removeItem(at: context.dmgURL)

            try await DMGBuildPipeline.build(
                configuration: configuration,
                assetsDirectory: assetsDirectory,
                outputURL: context.dmgURL,
                documentURL: resolved.designURL,
                progress: { progress in
                    await emit(.log(.buildDMG, progress.step))
                },
            )
            context.dmgSizeBytes = Self.fileSize(context.dmgURL)
            context.artifacts.append(context.dmgURL)

            if resolved.plan.artifacts.appZip {
                let zipURL = resolved.outputDirURL
                    .appending(path: "\(resolved.appName)-\(context.version).zip")
                try? FileManager.default.removeItem(at: zipURL)
                try await ProcessRunner.run(ExternalTool.ditto, arguments: [
                    "-c", "-k", "--keepParent", context.appSource.path, zipURL.path,
                ])
                context.artifacts.append(zipURL)
                await emit(.log(.buildDMG, "App zip: \(zipURL.lastPathComponent)"))
            }

            let size = ByteCountFormatter.string(fromByteCount: context.dmgSizeBytes, countStyle: .file)
            return .ok(detail: "\(context.dmgURL.lastPathComponent) · \(size)")
        }

        private static func fileSize(_ url: URL) -> Int64 {
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
                .flatMap { $0 } ?? 0
        }

        // MARK: - Verify

        /// Mounts the finished DMG and re-checks codesign, Gatekeeper, and
        /// every nested Mach-O. Nothing ships that wouldn't open cleanly on a
        /// stranger's Mac.
        private func verify(_ context: RunContext, _ emit: Emit) async throws -> StageOutcome {
            let mountPoint = FileManager.default.temporaryDirectory
                .appending(path: "rilmazafone-verify-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

            try await ProcessRunner.run(ExternalTool.hdiutil, arguments: [
                "attach", context.dmgURL.path,
                "-nobrowse", "-noverify", "-mountpoint", mountPoint.path,
            ])
            defer {
                Task {
                    _ = try? await ProcessRunner.run(
                        ExternalTool.hdiutil, arguments: ["detach", mountPoint.path, "-quiet"],
                    )
                }
            }

            let mountedApp = mountPoint.appending(path: "\(context.resolved.appName).app")
            guard FileManager.default.fileExists(atPath: mountedApp.path) else {
                throw ReleasePipelineError("App not found in DMG")
            }

            try await ProcessRunner.run(ExternalTool.codesign, arguments: [
                "--verify", "--deep", "--strict", mountedApp.path,
            ])
            await emit(.log(.verify, "Codesign: OK"))

            var checks = ["codesign"]
            if context.request.notarization == .wait {
                let result = try await ProcessRunner.run(
                    ExternalTool.spctl, arguments: ["-a", "-vvv", mountedApp.path],
                )
                let assessment = String(data: result.stderr, encoding: .utf8) ?? ""
                guard assessment.contains("source=Notarized Developer ID") else {
                    throw ReleasePipelineError("App not recognized as Notarized Developer ID:\n\(assessment)")
                }
                await emit(.log(.verify, "Gatekeeper: OK (Notarized Developer ID)"))
                checks.append("Gatekeeper")
            }

            var binaryCount = 0
            let enumerator = FileManager.default.enumerator(
                at: mountedApp, includingPropertiesForKeys: [.isRegularFileKey],
            )
            let mountedFiles = (enumerator?.allObjects ?? []).compactMap { $0 as? URL }
            do {
                for fileURL in mountedFiles where Self.isMachO(fileURL) {
                    do {
                        try await ProcessRunner.run(ExternalTool.codesign, arguments: [
                            "--verify", "--strict", fileURL.path,
                        ])
                    } catch {
                        throw ReleasePipelineError(
                            "Binary failed signature verification: \(fileURL.lastPathComponent)",
                        )
                    }
                    binaryCount += 1
                }
            }
            checks.append("\(binaryCount) binaries")

            return .ok(detail: checks.joined(separator: " · "))
        }

        // MARK: - EdDSA

        /// Signed AFTER stapling — the ticket changes the DMG bytes. Verifiers
        /// pin the public key (e.g. in Info.plist) and check before mounting.
        private func eddsaSign(_ context: RunContext) async throws -> StageOutcome {
            guard let keyURL = context.resolved.eddsaKeyURL,
                  FileManager.default.fileExists(atPath: keyURL.path)
            else {
                throw ReleasePipelineError("Ed25519 signing key not found")
            }
            guard let openssl = ExternalTool.find("openssl") else {
                throw ReleasePipelineError("openssl not found")
            }

            let rawSig = context.workDir.appending(path: "dmg-sig.bin")
            let publicKey = context.workDir.appending(path: "ed25519-pub.pem")
            defer {
                try? FileManager.default.removeItem(at: rawSig)
                try? FileManager.default.removeItem(at: publicKey)
            }

            try await ProcessRunner.run(openssl, arguments: [
                "pkeyutl", "-sign", "-inkey", keyURL.path,
                "-rawin", "-in", context.dmgURL.path, "-out", rawSig.path,
            ])
            try await ProcessRunner.run(openssl, arguments: [
                "pkey", "-in", keyURL.path, "-pubout", "-out", publicKey.path,
            ])
            try await ProcessRunner.run(openssl, arguments: [
                "pkeyutl", "-verify", "-pubin", "-inkey", publicKey.path,
                "-rawin", "-in", context.dmgURL.path, "-sigfile", rawSig.path,
            ])

            let signatureURL = context.dmgURL.appendingPathExtension("sig")
            let base64 = try Data(contentsOf: rawSig).base64EncodedString()
            try Data(base64.utf8).write(to: signatureURL)
            context.artifacts.append(signatureURL)
            return .ok(detail: signatureURL.lastPathComponent)
        }

        // MARK: - dSYMs

        /// Without preserved dSYMs, crash reports from shipped builds can't be
        /// symbolicated.
        private func archiveDSYMs(_ context: RunContext) async throws -> StageOutcome {
            let dsymSource = context.archivePath.appending(path: "dSYMs")
            guard FileManager.default.fileExists(atPath: dsymSource.path) else {
                return .skipped(reason: "no dSYMs in archive")
            }
            guard let targetDir = context.resolved.dsymArchiveDirURL?
                .appending(path: context.resolved.appName)
            else {
                return .skipped(reason: "no dSYM archive directory configured")
            }
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            let zipURL = targetDir.appending(
                path: "\(context.resolved.appName)-\(context.version)-b\(context.build)-dSYMs.zip",
            )
            try? FileManager.default.removeItem(at: zipURL)
            try await ProcessRunner.run(ExternalTool.ditto, arguments: [
                "-c", "-k", "--keepParent", dsymSource.path, zipURL.path,
            ])
            context.artifacts.append(zipURL)
            return .ok(detail: zipURL.lastPathComponent)
        }

        // MARK: - Commit + Push

        /// Publish's first stage — the point of no return. The commit must be
        /// on the remote BEFORE the GitHub release so the tag pins the real
        /// commit instead of whatever the remote's default branch pointed at.
        private func commitPush(_ context: RunContext, _ emit: Emit) async throws -> StageOutcome {
            let resolved = context.resolved
            var files = [resolved.pbxprojURL.path]
            if let constantURL = resolved.versionConstantURL {
                files.append(constantURL.path)
            }
            try await ProcessRunner.run(
                ExternalTool.git,
                arguments: ["-C", resolved.repoRoot.path, "add"] + files,
            )

            let message = "Bump version to v\(context.version) (build \(context.build))"
            do {
                try await ProcessRunner.run(
                    ExternalTool.git,
                    arguments: ["-C", resolved.repoRoot.path, "commit", "-m", message],
                )
            } catch let error as ProcessRunner.ProcessError where error.stderr.contains("nothing to commit") {
                await emit(.log(.commitPush, "Nothing to commit — bump already committed"))
            }
            context.releaseSHA = try await ProcessRunner.runString(
                ExternalTool.git,
                arguments: ["-C", resolved.repoRoot.path, "rev-parse", "HEAD"],
            )
            context.bumpApplied = false

            if resolved.plan.publish.channel == .github {
                do {
                    try await ProcessRunner.run(
                        ExternalTool.git,
                        arguments: ["-C", resolved.repoRoot.path, "push", "origin", "HEAD"],
                    )
                } catch {
                    throw ReleasePipelineError(
                        "Push failed — aborting before the release so its tag can't land on a stale commit",
                    )
                }
                return .ok(detail: "\u{201C}\(message)\u{201D} → origin")
            }
            return .ok(detail: "\u{201C}\(message)\u{201D} (no push — channel is not GitHub)")
        }

        // MARK: - GitHub Release

        private func githubRelease(_ context: RunContext, _ emit: Emit) async throws -> StageOutcome {
            guard let gh = ExternalTool.find("gh"),
                  let repo = context.resolved.plan.publish.githubRepo
            else {
                throw ReleasePipelineError("gh or repository unavailable")
            }
            let tag = "v\(context.version)"
            // Only artifacts in the output folder ship as release assets —
            // the DMG, its .sig, and the optional app zip. dSYM archives live
            // in their own directory and stay off the release.
            let outputPrefix = context.resolved.outputDirURL.path
            let assetPaths = context.artifacts
                .filter { $0.path.hasPrefix(outputPrefix) }
                .map(\.path)

            if context.request.republish {
                await emit(.log(.githubRelease, "Replacing assets on \(tag)…"))
                try await ProcessRunner.run(
                    gh,
                    arguments: ["release", "upload", tag] + assetPaths
                        + ["--repo", repo, "--clobber"],
                )
                context.releaseURL = "https://github.com/\(repo)/releases/tag/\(tag)"
                return .ok(detail: "assets replaced on \(tag)")
            }

            var notes = context.request.releaseNotes ?? ""
            if notes.isEmpty, let notesURL = context.resolved.notesFileURL {
                notes = (try? String(contentsOf: notesURL, encoding: .utf8)) ?? ""
            }

            var arguments = ["release", "create", tag] + assetPaths + [
                "--repo", repo,
                "--title", "\(context.resolved.appName) \(context.version)",
                "--notes", notes,
            ]
            if let sha = context.releaseSHA {
                arguments += ["--target", sha]
            }
            if context.request.prerelease || context.resolved.plan.publish.prerelease {
                arguments.append("--prerelease")
            }

            await emit(.log(.githubRelease, "Creating \(tag) on \(repo)…"))
            let result = try await ProcessRunner.run(gh, arguments: arguments)
            let output = String(data: result.stdout, encoding: .utf8) ?? ""
            context.releaseURL = output
                .split(separator: "\n")
                .first { $0.contains("/releases/tag/") }
                .map(String.init)
                ?? "https://github.com/\(repo)/releases/tag/\(tag)"
            return .ok(detail: context.releaseURL ?? tag)
        }

        // MARK: - Cask Bump

        /// Best-effort by design: the release itself already succeeded, so a
        /// tap failure reports status instead of failing the run.
        private func caskBump(_ context: RunContext, _ emit: Emit) async -> StageOutcome {
            guard let tapDir = context.resolved.homebrewTapDirURL else {
                return .skipped(reason: "no tap configured")
            }
            let caskName = context.resolved.plan.publish.homebrewCask
                ?? context.resolved.appName.lowercased()
            let caskURL = tapDir.appending(path: "Casks/\(caskName).rb")

            guard FileManager.default.fileExists(atPath: caskURL.path) else {
                let migrations = tapDir.appending(path: "tap_migrations.json")
                if let text = try? String(contentsOf: migrations, encoding: .utf8),
                   text.contains("\"\(caskName)\"") {
                    context.caskStatus = "in official homebrew/cask (autobumped from the release)"
                } else {
                    context.caskStatus = "no cask"
                }
                return .skipped(reason: context.caskStatus ?? "no cask")
            }

            do {
                try await ProcessRunner.run(
                    ExternalTool.git, arguments: ["-C", tapDir.path, "pull", "-q", "--ff-only"],
                )
            } catch {
                context.caskStatus = "FAILED (tap pull)"
                return .ok(detail: context.caskStatus ?? "")
            }

            do {
                let sha = try Self.sha256(of: context.dmgURL)
                let text = try String(contentsOf: caskURL, encoding: .utf8)
                let updated = text
                    .replacing(/\ \ version "[^"]*"/) { _ in "  version \"\(context.version)\"" }
                    .replacing(/\ \ sha256 "[^"]*"/) { _ in "  sha256 \"\(sha)\"" }
                if updated == text {
                    context.caskStatus = "already current"
                    return .ok(detail: context.caskStatus ?? "")
                }
                try updated.write(to: caskURL, atomically: true, encoding: .utf8)

                try await ProcessRunner.run(
                    ExternalTool.git, arguments: ["-C", tapDir.path, "add", caskURL.path],
                )
                try await ProcessRunner.run(ExternalTool.git, arguments: [
                    "-C", tapDir.path, "commit", "-q", "-m", "Bump \(caskName) to \(context.version)",
                ])
                try await ProcessRunner.run(
                    ExternalTool.git, arguments: ["-C", tapDir.path, "push", "-q"],
                )
                context.caskStatus = "bumped to \(context.version)"
                return .ok(detail: context.caskStatus ?? "")
            } catch {
                await emit(.log(.caskBump, "Cask update failed: \(error.localizedDescription)"))
                context.caskStatus = "FAILED (push)"
                return .ok(detail: context.caskStatus ?? "")
            }
        }

        private static func sha256(of url: URL) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }

        // MARK: - Publish Script

        private func runScript(_ context: RunContext, script: String?) async throws -> StageOutcome {
            guard let script else {
                return .skipped(reason: "no script")
            }
            let scriptURL = ReleasePlan.resolve(script, against: context.resolved.repoRoot)

            // Environment travels via a wrapper invocation of /usr/bin/env so
            // ProcessRunner stays environment-agnostic.
            var environment = [
                "RILMAZAFONE_APP=\(context.resolved.appName)",
                "RILMAZAFONE_VERSION=\(context.version)",
                "RILMAZAFONE_BUILD=\(context.build)",
                "RILMAZAFONE_DMG=\(context.dmgURL.path)",
                "RILMAZAFONE_REPO_ROOT=\(context.resolved.repoRoot.path)",
            ]
            environment.append(
                "RILMAZAFONE_ARTIFACTS=\(context.artifacts.map(\.path).joined(separator: ":"))",
            )
            if let releaseURL = context.releaseURL {
                environment.append("RILMAZAFONE_RELEASE_URL=\(releaseURL)")
            }
            if let notes = context.request.releaseNotes {
                environment.append("RILMAZAFONE_NOTES=\(notes)")
            }

            try await ProcessRunner.run(
                "/usr/bin/env",
                arguments: environment + [scriptURL.path],
                currentDirectory: context.resolved.repoRoot,
            )
            return .ok(detail: scriptURL.lastPathComponent)
        }

        // MARK: - Build Record

        private func saveBuildRecord(_ context: RunContext) throws {
            let record = BuildRecord(
                planIdentity: context.resolved.plan.identity,
                appName: context.resolved.appName,
                version: context.version,
                build: context.build,
                createdAt: Date(),
                dmgPath: context.dmgURL.path,
                dmgSizeBytes: context.dmgSizeBytes,
                archivePath: context.archivePath.path,
                extraArtifacts: context.artifacts.filter { $0 != context.dmgURL }.map(\.path),
                notarized: context.request.notarization == .wait,
                pendingSubmissionID: context.pendingSubmissionID,
                publishedURL: context.releaseURL,
            )
            try BuildRecordStore.save(record)
        }

        // MARK: - Async Staple

        /// Finishes an `--async-notarize` build: checks the pending submission
        /// and, once accepted, staples the DMG, re-signs the EdDSA signature
        /// (stapling changes the DMG bytes), and clears the record.
        static func staple(plan: ReleasePlan, planURL: URL) async throws -> BuildRecord {
            guard var record = BuildRecordStore.load(planIdentity: plan.identity) else {
                throw ReleasePipelineError("No build record for this plan.")
            }
            guard let submissionID = record.pendingSubmissionID else {
                throw ReleasePipelineError("No pending notarization — nothing to staple.")
            }
            let profile = plan.notarization.keychainProfile

            struct Info: Decodable { let status: String }
            let result = try await ProcessRunner.run(ExternalTool.xcrun, arguments: [
                "notarytool", "info", submissionID,
                "--keychain-profile", profile, "--output-format", "json",
            ])
            let info = try JSONDecoder().decode(Info.self, from: result.stdout)
            switch info.status {
            case "Accepted":
                break
            case "In Progress":
                throw ReleasePipelineError("Still in progress — try again in a few minutes.")
            default:
                throw ReleasePipelineError("Submission \(submissionID): \(info.status)")
            }

            try await ProcessRunner.run(
                ExternalTool.xcrun, arguments: ["stapler", "staple", record.dmgPath],
            )

            if let keyURL = (try? plan.resolve(planURL: planURL))?.eddsaKeyURL,
               FileManager.default.fileExists(atPath: keyURL.path),
               let openssl = ExternalTool.find("openssl") {
                let dmgURL = URL(fileURLWithPath: record.dmgPath)
                let rawSig = FileManager.default.temporaryDirectory
                    .appending(path: "rilmazafone-staple-sig-\(UUID().uuidString).bin")
                defer { try? FileManager.default.removeItem(at: rawSig) }
                try await ProcessRunner.run(openssl, arguments: [
                    "pkeyutl", "-sign", "-inkey", keyURL.path,
                    "-rawin", "-in", dmgURL.path, "-out", rawSig.path,
                ])
                let signatureURL = dmgURL.appendingPathExtension("sig")
                let base64 = try Data(contentsOf: rawSig).base64EncodedString()
                try Data(base64.utf8).write(to: signatureURL)
                if !record.extraArtifacts.contains(signatureURL.path) {
                    record.extraArtifacts.append(signatureURL.path)
                }
            }

            record.notarized = true
            record.pendingSubmissionID = nil
            record.dmgSizeBytes = fileSize(URL(fileURLWithPath: record.dmgPath))
            try BuildRecordStore.save(record)
            return record
        }

        // MARK: - Build Lock

        /// One archive at a time per machine, shared with `kagerou publish`.
        private static func acquireLock(emit: @Sendable (String) async -> Void) async throws {
            let pidURL = lockDirectory.appending(path: "pid")
            var announced = false
            for _ in 0 ..< 300 {
                do {
                    try FileManager.default.createDirectory(
                        at: lockDirectory, withIntermediateDirectories: false,
                    )
                    try? "\(ProcessInfo.processInfo.processIdentifier)".write(
                        to: pidURL, atomically: true, encoding: .utf8,
                    )
                    return
                } catch {
                    if let ownerPID = (try? String(contentsOf: pidURL, encoding: .utf8))
                        .flatMap({ Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
                        kill(ownerPID, 0) != 0 {
                        try? FileManager.default.removeItem(at: lockDirectory)
                        continue
                    }
                    if !announced {
                        await emit("Waiting for another build to finish (lock: \(lockDirectory.path))…")
                        announced = true
                    }
                    try await Task.sleep(for: .seconds(2))
                }
            }
            throw ReleasePipelineError("Timed out waiting for the build lock")
        }

        private static func releaseLock() {
            try? FileManager.default.removeItem(at: lockDirectory)
        }
    }
#endif
