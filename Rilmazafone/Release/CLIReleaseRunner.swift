#if !APPSTORE
    import Foundation

    /// Headless front-end for the release pipeline: `Rilmazafone release <cmd>`.
    /// GitHub build only — the App Store build compiles this out with the rest
    /// of the release feature.
    nonisolated enum CLIReleaseRunner {
        // MARK: - Entry

        /// Exit codes: 0 success · 1 pipeline failure · 2 usage error.
        static func run(arguments: [String]) -> Int32 {
            guard let command = arguments.first, command != "-h", command != "--help", command != "help" else {
                printUsage()
                return arguments.first == nil ? 2 : 0
            }
            let rest = Array(arguments.dropFirst())

            switch command {
            case "build": return runPhase([.build], arguments: rest)
            case "publish": return runPhase([.publish], arguments: rest)
            case "staple": return staple(arguments: rest)
            case "status": return status(arguments: rest)
            case "doctor": return doctor(arguments: rest)
            default:
                error("Unknown release command: \(command)")
                printUsage()
                return 2
            }
        }

        private static func printUsage() {
            let usage = """
            Usage: Rilmazafone release <command> <plan.releaseplan> [options]

            Commands:
              build     Archive, sign, notarize, build + verify the DMG (artifacts only)
              publish   Ship the latest build through the plan's channel
                        (builds first when no current build exists)
              staple    Finish an --async-notarize build once Apple accepts it
              status    Show the latest build record
              doctor    Preflight checks without running anything

            Options:
              -v, --version X.Y[.Z]   Explicit version (default: plan's bump policy)
              -n, --notes TEXT        Release notes (publish)
              -f, --notes-file FILE   Release notes from a file (publish)
              -p, --prerelease        Mark the GitHub release as a prerelease
              --skip-notarize         No notarization (Gatekeeper will block it elsewhere)
              --async-notarize        Submit, then `release staple` later
              --republish             Rebuild current version, clobber release assets
              --json                  Stage events as NDJSON on stdout

            Exit codes: 0 success · 1 pipeline failure · 2 usage error.
            Runs append to <output folder>/work/release.log.
            """
            fputs(usage + "\n", stderr)
        }

        // MARK: - Options

        private struct Options {
            var planURL: URL
            var plan: ReleasePlan
            var version: String?
            var notes: String?
            var prerelease = false
            var notarization: NotarizationMode = .wait
            var republish = false
            var json = false
        }

        private static func parse(_ arguments: [String]) -> Options? {
            var planPath: String?
            var options: [String] = []
            var iterator = arguments.makeIterator()

            var version: String?
            var notes: String?
            var prerelease = false
            var notarization = NotarizationMode.wait
            var republish = false
            var json = false

            while let argument = iterator.next() {
                switch argument {
                case "-v", "--version":
                    version = iterator.next()
                case "-n", "--notes":
                    notes = iterator.next()
                case "-f", "--notes-file":
                    guard let path = iterator.next(),
                          let contents = try? String(
                              contentsOf: URL(fileURLWithPath: path), encoding: .utf8,
                          )
                    else {
                        error("Notes file not found")
                        return nil
                    }
                    notes = contents
                case "-p", "--prerelease":
                    prerelease = true
                case "--skip-notarize":
                    notarization = .skip
                case "--async-notarize":
                    notarization = .async
                case "--republish":
                    republish = true
                case "--json":
                    json = true
                default:
                    if argument.hasPrefix("-") {
                        options.append(argument)
                    } else if planPath == nil {
                        planPath = argument
                    }
                }
            }
            if !options.isEmpty {
                error("Unknown option: \(options[0])")
                return nil
            }
            guard let planPath else {
                error("Missing <plan.releaseplan> argument")
                return nil
            }

            let planURL = URL(fileURLWithPath: planPath)
            guard let data = try? Data(contentsOf: planURL.appending(path: "plan.json")),
                  let plan = try? JSONDecoder().decode(ReleasePlan.self, from: data)
            else {
                error(ReleasePlanError.notAPlan(planURL).localizedDescription)
                return nil
            }

            return Options(
                planURL: planURL, plan: plan, version: version, notes: notes,
                prerelease: prerelease, notarization: notarization,
                republish: republish, json: json,
            )
        }

        // MARK: - Build / Publish

        private static func runPhase(_ phases: Set<ReleaseStage.Phase>, arguments: [String]) -> Int32 {
            guard let options = parse(arguments) else { return 2 }

            // `publish` with no current build runs the whole pipeline.
            var effectivePhases = phases
            if phases == [.publish] {
                let record = BuildRecordStore.load(planIdentity: options.plan.identity)
                let current = record.map { $0.dmgExists && $0.pendingSubmissionID == nil } ?? false
                if !current {
                    progress("No current build — running build + publish.")
                    effectivePhases = [.build, .publish]
                }
            }

            let request = ReleaseRunRequest(
                plan: options.plan,
                planURL: options.planURL,
                phases: effectivePhases,
                versionOverride: options.version,
                releaseNotes: options.notes,
                prerelease: options.prerelease,
                notarization: options.notarization,
                republish: options.republish,
            )

            // Every run appends its transcript to the plan's release log —
            // the durable record kagerou's per-app log file used to be.
            let logURL = (try? options.plan.resolve(planURL: options.planURL))
                .map { $0.outputDirURL.appending(path: "work/release.log") }

            return waitFor {
                let printer = EventPrinter(json: options.json, logURL: logURL)
                printer.logLine(
                    "=== \(Date().formatted(.iso8601)) · \(request.phases.map(\.rawValue).sorted().joined(separator: "+")) ===",
                )
                do {
                    let summary = try await ReleasePipeline().run(request) { event in
                        printer.print(event)
                    }
                    if !options.json {
                        printSummary(summary)
                        if let logURL {
                            print("  log:      \(logURL.path)")
                        }
                    }
                    printer.logLine("RESULT: success")
                    return 0
                } catch {
                    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    printer.logLine("RESULT: failed — \(message)")
                    Self.error(message)
                    if let logURL {
                        Self.error("log: \(logURL.path)")
                    }
                    return 1
                }
            }
        }

        private static func printSummary(_ summary: ReleaseSummary) {
            print("")
            print("\(summary.appName) \(summary.version) (build \(summary.build)) — done in \(EventPrinter.format(summary.elapsed))")
            for artifact in summary.artifacts {
                print("  artifact: \(artifact.path)")
            }
            if let url = summary.releaseURL {
                print("  release:  \(url)")
            }
            if let cask = summary.caskStatus {
                print("  cask:     \(cask)")
            }
            if summary.notarization == .async {
                print("  notarization pending — run: Rilmazafone release staple <plan>")
            }
        }

        // MARK: - Staple / Status / Doctor

        private static func staple(arguments: [String]) -> Int32 {
            guard let options = parse(arguments) else { return 2 }
            return waitFor {
                do {
                    let record = try await ReleasePipeline.staple(
                        plan: options.plan, planURL: options.planURL,
                    )
                    print("Stapled: \(record.dmgPath)")
                    return 0
                } catch {
                    Self.error((error as? LocalizedError)?.errorDescription ?? "\(error)")
                    return 1
                }
            }
        }

        private static func status(arguments: [String]) -> Int32 {
            guard let options = parse(arguments) else { return 2 }
            guard let record = BuildRecordStore.load(planIdentity: options.plan.identity) else {
                print("No build record — nothing has been built for this plan.")
                return 0
            }
            let size = ByteCountFormatter.string(fromByteCount: record.dmgSizeBytes, countStyle: .file)
            print("\(record.appName) v\(record.version) (build \(record.build)) · \(record.createdAt.formatted())")
            print("  dmg: \(record.dmgPath) (\(size))\(record.dmgExists ? "" : " — MISSING")")
            for extra in record.extraArtifacts {
                print("  artifact: \(extra)")
            }
            if let pending = record.pendingSubmissionID {
                print("  notarization: pending (submission \(pending)) — run `release staple`")
            } else {
                print("  notarization: \(record.notarized ? "accepted + stapled" : "skipped")")
            }
            print("  published: \(record.publishedURL ?? "not yet")")
            return 0
        }

        private static func doctor(arguments: [String]) -> Int32 {
            guard let options = parse(arguments) else { return 2 }
            return waitFor {
                do {
                    let resolved = try options.plan.resolve(planURL: options.planURL)
                    print("repo root:  \(resolved.repoRoot.path)")
                    print("project:    \(resolved.xcodeprojURL.lastPathComponent) · scheme \(resolved.scheme)")
                    if let version = PlanAutoDetection.projectVersion(pbxprojURL: resolved.pbxprojURL) {
                        print("version:    \(version.marketing) (\(version.build))")
                    }
                    print("design:     \(resolved.designURL.path)")

                    let identity = options.plan.signing.identity ?? PlanAutoDetection.developerIDIdentity()
                    print("identity:   \(identity ?? "MISSING — no Developer ID Application in keychain")")

                    let profile = options.plan.notarization.keychainProfile
                    if profile.isEmpty {
                        print("notary:     not configured")
                    } else {
                        let ok = await PlanAutoDetection.verifyNotaryProfile(profile)
                        print("notary:     \(profile) \(ok ? "· OK" : "· FAILED (notarytool can't use it)")")
                    }

                    if options.plan.publish.channel == .github {
                        var repo = options.plan.publish.githubRepo
                        if repo == nil {
                            repo = await PlanAutoDetection.githubRepo(repoRoot: resolved.repoRoot)
                        }
                        if let repo {
                            let ok = await PlanAutoDetection.verifyGitHubRepo(repo)
                            print("github:     \(repo) \(ok ? "· push OK" : "· no push access / gh unauthenticated")")
                        } else {
                            print("github:     no repository set and none detected from the git remote")
                        }
                    }
                    return 0
                } catch {
                    Self.error((error as? LocalizedError)?.errorDescription ?? "\(error)")
                    return 1
                }
            }
        }

        // MARK: - Event Printing

        /// Serializes event output; also the NDJSON encoder for `--json` and
        /// the appender for the persistent release log.
        private final class EventPrinter: @unchecked Sendable {
            private let json: Bool
            private let logHandle: FileHandle?
            private let lock = NSLock()
            private let encoder: JSONEncoder = {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                return encoder
            }()

            init(json: Bool, logURL: URL? = nil) {
                self.json = json
                self.logHandle = logURL.flatMap { url in
                    try? FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                    )
                    if !FileManager.default.fileExists(atPath: url.path) {
                        FileManager.default.createFile(atPath: url.path, contents: nil)
                    }
                    guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
                    try? handle.seekToEnd()
                    return handle
                }
            }

            /// Appends one line to the release log (never to the console).
            func logLine(_ line: String) {
                lock.lock()
                defer { lock.unlock() }
                appendToLog(line)
            }

            private func appendToLog(_ line: String) {
                try? logHandle?.write(contentsOf: Data((line + "\n").utf8))
            }

            private struct JSONEvent: Encodable {
                let event: String
                let stage: String?
                var outcome: String?
                var detail: String?
                var elapsedSeconds: Double?
                var message: String?
            }

            func print(_ event: StageEvent) {
                lock.lock()
                defer { lock.unlock() }
                if json {
                    printJSON(event)
                } else {
                    printText(event)
                }
            }

            private func printText(_ event: StageEvent) {
                if let line = Self.textLine(for: event) {
                    Swift.print(line)
                    appendToLog(line)
                }
            }

            private static func textLine(for event: StageEvent) -> String? {
                switch event {
                case let .stageBegan(id):
                    "▸ \(ReleaseStage.stage(id).title)…"
                case let .log(_, line):
                    "    \(line)"
                case let .stageEnded(id, outcome, elapsed):
                    switch outcome {
                    case let .ok(detail):
                        "✓ \(ReleaseStage.stage(id).title)  \(detail)  [\(format(elapsed))]"
                    case let .skipped(reason):
                        "· \(ReleaseStage.stage(id).title)  \(reason)"
                    case let .failed(message):
                        "✗ \(ReleaseStage.stage(id).title)  \(message)"
                    }
                case .finished:
                    nil
                }
            }

            private func printJSON(_ event: StageEvent) {
                let payload: JSONEvent = switch event {
                case let .stageBegan(id):
                    JSONEvent(event: "stageBegan", stage: id.rawValue)
                case let .log(id, line):
                    JSONEvent(event: "log", stage: id.rawValue, message: line)
                case let .stageEnded(id, outcome, elapsed):
                    switch outcome {
                    case let .ok(detail):
                        JSONEvent(
                            event: "stageEnded", stage: id.rawValue, outcome: "ok",
                            detail: detail, elapsedSeconds: Self.seconds(elapsed),
                        )
                    case let .skipped(reason):
                        JSONEvent(
                            event: "stageEnded", stage: id.rawValue, outcome: "skipped",
                            detail: reason, elapsedSeconds: Self.seconds(elapsed),
                        )
                    case let .failed(message):
                        JSONEvent(
                            event: "stageEnded", stage: id.rawValue, outcome: "failed",
                            detail: message, elapsedSeconds: Self.seconds(elapsed),
                        )
                    }
                case let .finished(summary):
                    JSONEvent(
                        event: "finished", stage: nil,
                        detail: "\(summary.appName) \(summary.version) (\(summary.build))",
                        elapsedSeconds: Self.seconds(summary.elapsed),
                    )
                }
                if let data = try? encoder.encode(payload),
                   let line = String(data: data, encoding: .utf8) {
                    Swift.print(line)
                }
                // The log stays human-readable even when stdout is NDJSON.
                if let line = Self.textLine(for: event) {
                    appendToLog(line)
                }
            }

            static func seconds(_ duration: Duration) -> Double {
                Double(duration.components.seconds)
                    + Double(duration.components.attoseconds) / 1e18
            }

            static func format(_ duration: Duration) -> String {
                let seconds = Int(duration.components.seconds)
                return seconds >= 60
                    ? "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
                    : "\(seconds)s"
            }
        }

        // MARK: - Async Bridge

        /// Same semaphore bridge `CLIBuildRunner` uses to run async work from
        /// the synchronous CLI entry point.
        private static func waitFor(_ body: @escaping @Sendable () async -> Int32) -> Int32 {
            let semaphore = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var exitCode: Int32 = 1
            Task { @Sendable in
                exitCode = await body()
                semaphore.signal()
            }
            semaphore.wait()
            return exitCode
        }

        // MARK: - Output

        private static func progress(_ message: String) {
            fputs("rilmazafone: \(message)\n", stderr)
        }

        private static func error(_ message: String) {
            fputs("rilmazafone: error: \(message)\n", stderr)
        }
    }
#endif
