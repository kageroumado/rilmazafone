#if !APPSTORE
    import Foundation
    import Observation

    // MARK: - Run Model

    /// Observable store behind the plan window's run UI. Consumes one runner's
    /// event stream and mirrors it as view state; the views never touch the
    /// engine directly, so the debug scenario menu can swap in a scripted
    /// runner and exercise any state.
    @Observable
    @MainActor
    final class ReleaseRunModel {
        // MARK: - State

        enum RunState: Equatable {
            case idle
            case running
            case finished
            case failed(String)
        }

        enum StageStatus: Equatable {
            case pending
            case running
            case ok(detail: String, elapsed: Duration)
            case skipped(reason: String)
            case failed(message: String)
        }

        struct StageRow: Identifiable {
            let stage: ReleaseStage
            var status: StageStatus = .pending

            var id: ReleaseStage.ID { stage.id }
        }

        private(set) var state: RunState = .idle
        private(set) var stages: [StageRow] = []
        private(set) var logLines: [String] = []
        private(set) var summary: ReleaseSummary?

        /// The latest build record for the open plan, refreshed after runs.
        private(set) var buildRecord: BuildRecord?

        @ObservationIgnored private var runTask: Task<Void, Never>?

        var isRunning: Bool {
            state == .running
        }

        var phaseLabel: String {
            let running = stages.first { $0.status == .running }
            return running?.stage.title ?? ""
        }

        // MARK: - Record

        func refreshBuildRecord(planIdentity: UUID) {
            buildRecord = BuildRecordStore.load(planIdentity: planIdentity)
        }

        /// A record is current when it exists, still has its DMG on disk, and
        /// isn't awaiting an async staple.
        var hasCurrentBuild: Bool {
            guard let buildRecord else { return false }
            return buildRecord.dmgExists && buildRecord.pendingSubmissionID == nil
        }

        // MARK: - Run

        func start(request: ReleaseRunRequest, runner: any ReleaseRunning) {
            guard !isRunning else { return }
            state = .running
            summary = nil
            logLines = []
            stages = ReleasePipeline.stagePlan(for: request).map { StageRow(stage: $0) }
            let planIdentity = request.plan.identity

            runTask = Task {
                do {
                    _ = try await runner.run(request) { [weak self] event in
                        await self?.apply(event)
                    }
                    state = .finished
                } catch is CancellationError {
                    state = .idle
                } catch {
                    state = .failed(error.localizedDescription)
                }
                refreshBuildRecord(planIdentity: planIdentity)
            }
        }

        func cancel() {
            runTask?.cancel()
            runTask = nil
            if isRunning {
                state = .idle
            }
        }

        func reset() {
            cancel()
            state = .idle
            stages = []
            logLines = []
            summary = nil
        }

        // MARK: - Event Application

        private func apply(_ event: StageEvent) {
            switch event {
            case let .stageBegan(id):
                setStatus(.running, for: id)
            case let .log(_, line):
                logLines.append(line)
                if logLines.count > 200 {
                    logLines.removeFirst(logLines.count - 200)
                }
            case let .stageEnded(id, outcome, elapsed):
                switch outcome {
                case let .ok(detail):
                    setStatus(.ok(detail: detail, elapsed: elapsed), for: id)
                case let .skipped(reason):
                    setStatus(.skipped(reason: reason), for: id)
                case let .failed(message):
                    setStatus(.failed(message: message), for: id)
                }
            case let .finished(summary):
                self.summary = summary
            }
        }

        private func setStatus(_ status: StageStatus, for id: ReleaseStage.ID) {
            guard let index = stages.firstIndex(where: { $0.id == id }) else { return }
            stages[index].status = status
        }
    }
#endif
