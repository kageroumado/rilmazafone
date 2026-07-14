import AppKit
import Foundation
import Observation

// MARK: - Validation

nonisolated enum ValidationError: Error, LocalizedError {
    case missingSourceFile(String)
    case volumeNameEmpty
    case volumeNameTooLong(Int)
    case duplicateLabels([String])

    var errorDescription: String? {
        switch self {
        case let .missingSourceFile(path):
            "Source file not found: \(path)"
        case .volumeNameEmpty:
            "Volume name cannot be empty."
        case let .volumeNameTooLong(count):
            "Volume name is \(count) characters (maximum 27)."
        case let .duplicateLabels(labels):
            "Duplicate item names: \(labels.joined(separator: ", "))"
        }
    }
}

// MARK: - Build Manager

@Observable
final class BuildManager {
    // MARK: - Build State

    enum BuildState: Equatable {
        case idle
        case building(BuildProgress)
        case completed(URL)
        case failed(String)
    }

    struct BuildProgress: Equatable {
        var currentStep: String
        var stepIndex: Int
        var totalSteps: Int

        var fraction: Double {
            guard totalSteps > 0 else { return 0 }
            return Double(stepIndex - 1) / Double(totalSteps)
        }
    }

    private(set) var state: BuildState = .idle

    @ObservationIgnored private var buildTask: Task<Void, Never>?

    var isBuilding: Bool {
        if case .building = state { return true }
        return false
    }

    var isShowingSheet: Bool {
        state != .idle
    }

    // MARK: - Build

    func build(
        configuration: DMGConfiguration,
        assetsDirectory: URL,
        outputURL: URL
    ) {
        buildTask = Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await DMGBuildPipeline.build(
                    configuration: configuration,
                    assetsDirectory: assetsDirectory,
                    outputURL: outputURL,
                    progress: { [weak self] progress in
                        await self?.applyProgress(progress)
                    }
                )
                await MainActor.run { self.state = .completed(outputURL) }
            } catch is CancellationError {
                await MainActor.run { self.state = .idle }
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
            }

            try? FileManager.default.removeItem(at: assetsDirectory)
        }
    }

    func reportError(_ message: String) {
        state = .failed(message)
    }

    func reset() {
        buildTask?.cancel()
        buildTask = nil
        state = .idle
    }

    // MARK: - Progress

    private func applyProgress(_ progress: DMGBuildPipeline.Progress) {
        state = .building(BuildProgress(
            currentStep: progress.step,
            stepIndex: progress.stepIndex,
            totalSteps: progress.totalSteps
        ))
    }
}
