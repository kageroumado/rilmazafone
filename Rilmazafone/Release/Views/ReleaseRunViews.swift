#if !APPSTORE
    import AppKit
    import SwiftUI

    // MARK: - Pipeline View

    /// The plan window's content — the pipeline as the document's subject,
    /// centered like the canvas in the design editor. Idle, it shows the
    /// stages this plan will execute plus the latest build; during a run the
    /// same rows go live, marking stages as they complete, with overall
    /// progress at the top and the failure (if any) explained in place.
    struct PipelineView: View {
        @Environment(ReleasePlanDocument.self) private var document
        @Environment(ReleaseRunModel.self) private var runModel

        @State private var stapleError: String?
        @State private var isStapling = false

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if runModel.state == .idle {
                        idleRail
                    } else {
                        liveRail
                    }
                }
                .frame(maxWidth: 480, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .alert(
                "Staple Failed",
                isPresented: Binding(get: { stapleError != nil }, set: { if !$0 { stapleError = nil } }),
            ) {
                Button("OK") { stapleError = nil }
            } message: {
                Text(stapleError ?? "")
            }
        }

        // MARK: Idle

        /// The pipeline as a promise: whether it can run at all, what Build and Publish
        /// will do, and where the last build stands.
        @ViewBuilder
        private var idleRail: some View {
            readinessHeader
            let stages = ReleasePipeline.stagePlan(for: ReleaseRunRequest(
                plan: document.plan,
                planURL: document.fileURL ?? URL(fileURLWithPath: "/"),
                phases: [.build, .publish],
            ))

            phaseHeader(.build)
            ForEach(stages.filter { $0.phase == .build }) { stage in
                nominalRow(stage, done: runModel.hasCurrentBuild)
            }

            if let record = runModel.buildRecord {
                BuildRecordCard(
                    record: record,
                    isStapling: isStapling,
                    onStaple: staple,
                )
                .padding(.vertical, 6)
            }

            if document.plan.publish.channel != .none {
                seam
                phaseHeader(.publish)
                ForEach(stages.filter { $0.phase == .publish }) { stage in
                    nominalRow(stage, done: false)
                }
                if let published = runModel.buildRecord?.publishedURL {
                    Text(published)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.top, 4)
                        .textSelection(.enabled)
                }
            }
        }

        // MARK: Readiness

        private var readiness: PlanReadiness {
            PlanReadiness.evaluate(
                plan: document.plan,
                detection: document.detection,
                planURL: document.fileURL,
            )
        }

        /// Preflight's answer, before anyone presses a button.
        ///
        /// Quiet when the plan is runnable — one line, because "yes" needs no detail.
        /// When it is not, the checks that stand in the way, each naming what to do.
        @ViewBuilder
        private var readinessHeader: some View {
            let readiness = readiness

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: readinessSymbol(readiness))
                        .foregroundStyle(readinessTint(readiness))
                        .font(.callout)
                    Text(readiness.summary)
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                }

                if !readiness.isConfigured {
                    Text("Choose a repository in the Project tab to get started.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Passing checks stay silent: the headline already said so.
                    ForEach(readiness.checks.filter { $0.status != .ok }) { check in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: check.status == .blocked
                                ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(check.status == .blocked
                                    ? AnyShapeStyle(.red) : AnyShapeStyle(.orange))
                                .font(.caption)
                            Text(check.title)
                                .font(.caption)
                            Text(check.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(.bottom, 14)
            .accessibilityElement(children: .combine)
        }

        private func readinessSymbol(_ readiness: PlanReadiness) -> String {
            if !readiness.isConfigured { return "circle.dashed" }
            if !readiness.blocked.isEmpty { return "exclamationmark.circle.fill" }
            if !readiness.warnings.isEmpty { return "exclamationmark.triangle.fill" }
            return "checkmark.circle.fill"
        }

        private func readinessTint(_ readiness: PlanReadiness) -> AnyShapeStyle {
            if !readiness.isConfigured { return AnyShapeStyle(.tertiary) }
            if !readiness.blocked.isEmpty { return AnyShapeStyle(.red) }
            if !readiness.warnings.isEmpty { return AnyShapeStyle(.orange) }
            return AnyShapeStyle(.green)
        }

        private func nominalRow(_ stage: ReleaseStage, done: Bool) -> some View {
            HStack(spacing: 7) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.quaternary))
                    .font(.caption)
                Text(stage.title)
                    .font(.callout)
                    .foregroundStyle(done ? .primary : .secondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 1)
        }

        // MARK: Live

        @ViewBuilder
        private var liveRail: some View {
            overallProgress

            ForEach(groupedStages, id: \.0) { phase, rows in
                phaseHeader(phase)
                ForEach(rows) { row in
                    LiveStageRow(row: row)
                }
                if phase == .build, groupedStages.count == 2 {
                    seam
                }
            }

            if let failure = failedRow {
                FailureCard(row: failure)
                    .padding(.top, 8)
            }

            if let summary = runModel.summary {
                RunSummaryCard(summary: summary)
                    .padding(.top, 8)
            }

            if !runModel.logLines.isEmpty, runModel.summary == nil, failedRow == nil {
                logTail
            }

            if case .finished = runModel.state {
                dismissRow
            } else if case .failed = runModel.state {
                dismissRow
            } else if runModel.isRunning {
                HStack {
                    Spacer()
                    Button("Cancel") { runModel.cancel() }
                        .controlSize(.small)
                }
                .padding(.top, 8)
            }
        }

        private var overallProgress: some View {
            let total = runModel.stages.count
            let done = runModel.stages.count { row in
                if case .ok = row.status { return true }
                if case .skipped = row.status { return true }
                return false
            }
            return VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                if runModel.isRunning {
                    Text("Stage \(min(done + 1, total)) of \(total) — \(runModel.phaseLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 6)
        }

        private var groupedStages: [(ReleaseStage.Phase, [ReleaseRunModel.StageRow])] {
            let build = runModel.stages.filter { $0.stage.phase == .build }
            let publish = runModel.stages.filter { $0.stage.phase == .publish }
            var groups: [(ReleaseStage.Phase, [ReleaseRunModel.StageRow])] = []
            if !build.isEmpty { groups.append((.build, build)) }
            if !publish.isEmpty { groups.append((.publish, publish)) }
            return groups
        }

        private var failedRow: ReleaseRunModel.StageRow? {
            runModel.stages.first { row in
                if case .failed = row.status { return true }
                return false
            }
        }

        private var logTail: some View {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(runModel.logLines.suffix(5).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.top, 8)
        }

        private var dismissRow: some View {
            HStack {
                Spacer()
                Button("Clear") {
                    runModel.reset()
                    runModel.refreshBuildRecord(planIdentity: document.plan.identity)
                }
                .controlSize(.small)
            }
            .padding(.top, 8)
        }

        // MARK: Shared

        private func phaseHeader(_ phase: ReleaseStage.Phase) -> some View {
            HStack {
                Text(phase == .build ? "BUILD" : "PUBLISH")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if phase == .publish {
                    Spacer()
                    Text("fixes forward")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Publish is past the point of no return: failures never roll back — fix the cause and publish again")
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 3)
        }

        private var seam: some View {
            HStack(spacing: 6) {
                Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                Text("POINT OF NO RETURN")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                Rectangle().frame(height: 1).foregroundStyle(.quaternary)
            }
            .padding(.vertical, 8)
        }

        private func staple() {
            isStapling = true
            let plan = document.plan
            let planURL = document.fileURL ?? URL(fileURLWithPath: "/")
            Task {
                do {
                    _ = try await ReleasePipeline.staple(plan: plan, planURL: planURL)
                } catch {
                    stapleError = error.localizedDescription
                }
                runModel.refreshBuildRecord(planIdentity: plan.identity)
                isStapling = false
            }
        }
    }

    // MARK: - Live Stage Row

    struct LiveStageRow: View {
        let row: ReleaseRunModel.StageRow

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                statusIcon
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.stage.title)
                        .font(.callout.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(titleStyle)
                    // The detail line is always laid out — rows keeping one
                    // height means the list doesn't jump as stages complete.
                    Text(detail.isEmpty ? " " : detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if case let .ok(_, elapsed) = row.status {
                    Text(DurationFormat.short(elapsed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
        }

        private var isActive: Bool {
            row.status == .running
        }

        private var titleStyle: HierarchicalShapeStyle {
            switch row.status {
            case .pending: .tertiary
            default: .primary
            }
        }

        @ViewBuilder
        private var statusIcon: some View {
            switch row.status {
            case .pending:
                Image(systemName: "circle")
                    .foregroundStyle(.quaternary)
                    .font(.caption)
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .ok:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            case .skipped:
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }

        private var detail: String {
            switch row.status {
            case .pending, .running:
                ""
            case let .ok(detail, _):
                detail
            case let .skipped(reason):
                reason
            case .failed:
                // The failure card below carries the message and the fix.
                ""
            }
        }
    }

    // MARK: - Failure Card

    /// Failures explain themselves where they happen: the message, plus what
    /// to actually do about it for the cases first-time releasers hit.
    struct FailureCard: View {
        let row: ReleaseRunModel.StageRow

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(row.stage.title) failed", systemImage: "xmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = ReleaseRemediation.hint(for: row.stage.id, message: message) {
                    Text(hint)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.red.opacity(0.07))
                    .stroke(.red.opacity(0.3), lineWidth: 1),
            )
        }

        private var message: String {
            if case let .failed(message) = row.status { return message }
            return ""
        }
    }

    /// One paragraph per failure class, written for someone shipping their
    /// first app — what went wrong and the concrete next step.
    nonisolated enum ReleaseRemediation {
        static func hint(for id: ReleaseStage.ID, message: String) -> String? {
            switch id {
            case .notarizeApp, .notarizeDMG:
                if message.contains("store-credentials") || message.lowercased().contains("keychain") {
                    return "Notarization needs stored credentials: run "
                        + "\u{201C}xcrun notarytool store-credentials\u{201D} in Terminal once "
                        + "(the ⓘ next to Notary profile has the full command), then set the "
                        + "profile name in the plan."
                }
                return "Apple rejected the build — the log above says why. The usual culprit "
                    + "is a nested binary that isn't signed with Developer ID; every helper, "
                    + "framework, and bundled tool must be signed."
            case .archive:
                return "The Xcode build itself failed. Open the project and fix the errors — "
                    + "the same ones ⌘B in Xcode would show."
            case .sign:
                return "Check that the Developer ID Application certificate (with its private "
                    + "key) is in your keychain — Xcode ▸ Settings ▸ Accounts ▸ Manage "
                    + "Certificates can create one."
            case .commitPush:
                return "Nothing was published. Pull or fix the remote, then publish again — "
                    + "the release must tag a commit that exists on GitHub."
            case .githubRelease:
                return "The commit is pushed but the release didn't go up. Fix the cause and "
                    + "publish again — the existing build is reused, nothing rebuilds."
            case .preflight:
                return nil // Preflight messages already state the fix.
            default:
                return nil
            }
        }
    }

    // MARK: - Build Record Card

    struct BuildRecordCard: View {
        let record: BuildRecord
        var isStapling = false
        var onStaple: () -> Void = {}

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: record.dmgExists ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(record.dmgExists ? .green : .yellow)
                    Text("Build #\(record.build) — v\(record.version)")
                        .font(.callout.weight(.semibold))
                }
                Text(statusLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: record.dmgPath)],
                        )
                    }
                    .controlSize(.small)
                    if record.pendingSubmissionID != nil {
                        Button(isStapling ? "Stapling\u{2026}" : "Staple") { onStaple() }
                            .controlSize(.small)
                            .disabled(isStapling)
                            .help("Check the pending notarization and attach the ticket")
                    }
                }
                .padding(.top, 2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.green.opacity(0.08))
                    .stroke(.green.opacity(0.35), lineWidth: 1),
            )
        }

        private var statusLine: String {
            let size = ByteCountFormatter.string(fromByteCount: record.dmgSizeBytes, countStyle: .file)
            let name = URL(fileURLWithPath: record.dmgPath).lastPathComponent
            var parts = ["\(name) · \(size)"]
            if record.pendingSubmissionID != nil {
                parts.append("notarization pending")
            } else if record.notarized {
                parts.append("notarized + stapled")
            } else {
                parts.append("not notarized")
            }
            if !record.dmgExists {
                parts.append("missing on disk")
            }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - Summary

    struct RunSummaryCard: View {
        let summary: ReleaseSummary

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "\(summary.appName) \(summary.version) (build \(summary.build))",
                    systemImage: "checkmark.seal.fill",
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    if let size = summary.dmgSizeBytes {
                        summaryRow("DMG", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    if let url = summary.releaseURL {
                        summaryRow("Release", url)
                    }
                    if let sha = summary.commitSHA {
                        summaryRow("Commit", String(sha.prefix(9)))
                    }
                    if let cask = summary.caskStatus {
                        summaryRow("Cask", cask)
                    }
                    if summary.notarization == .async {
                        summaryRow("Notarize", "pending — Staple when accepted")
                    }
                    summaryRow("Elapsed", DurationFormat.short(summary.elapsed))
                }
                .font(.caption)

                if !summary.artifacts.isEmpty {
                    Button("Reveal Artifacts") {
                        NSWorkspace.shared.activateFileViewerSelecting(summary.artifacts)
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.green.opacity(0.08))
                    .stroke(.green.opacity(0.35), lineWidth: 1),
            )
        }

        private func summaryRow(_ label: String, _ value: String) -> some View {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    // MARK: - Duration Formatting

    nonisolated enum DurationFormat {
        static func short(_ duration: Duration) -> String {
            let seconds = Int(duration.components.seconds)
            return seconds >= 60
                ? "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
                : "\(seconds)s"
        }
    }
#endif
