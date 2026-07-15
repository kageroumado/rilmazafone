import SwiftUI

struct BuildSheet: View {
    @Environment(BuildManager.self) private var buildManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if case let .building(progress) = buildManager.state {
                BuildingContent(progress: progress)
                    .transition(.blurReplace)
            }

            if case let .completed(url) = buildManager.state {
                CompletedContent(url: url)
                    .transition(.blurReplace)
            }

            if case let .failed(message) = buildManager.state {
                FailedContent(message: message)
                    .transition(.blurReplace)
            }
        }
        .frame(width: 380, height: 240)
        .animation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.15), value: phaseKey)
    }

    private var phaseKey: String {
        switch buildManager.state {
        case .idle: "idle"
        case .building: "building"
        case .completed: "completed"
        case .failed: "failed"
        }
    }
}

// MARK: - Building

private struct BuildingContent: View {
    let progress: BuildManager.BuildProgress
    @Environment(BuildManager.self) private var buildManager
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 4)

                Circle()
                    .trim(from: 0, to: progress.fraction)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: progress.fraction)

                Text("\(progress.stepIndex)")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: progress.stepIndex)
            }
            .frame(width: 48, height: 48)
            .accessibilityLabel(
                "Build progress, step \(progress.stepIndex) of \(progress.totalSteps), \(progress.currentStep)",
            )

            VStack(spacing: 6) {
                Text("Building DMG")
                    .font(.headline)

                Text(progress.currentStep)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: progress.currentStep)
            }

            Button("Cancel", role: .cancel) {
                buildManager.reset()
            }
            .controlSize(.small)

            // Passive, non-blocking legibility notice — the build proceeds either
            // way; this just repeats the toolbar chip's warning at commit time.
            if let summary = document.legibilitySummary {
                Label(summary, systemImage: "textformat.abc")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(summary)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Completed

private struct CompletedContent: View {
    let url: URL
    @Environment(BuildManager.self) private var buildManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: reduceMotion ? false : appeared)

            VStack(spacing: 4) {
                Text("Build Successful")
                    .font(.headline)

                Text(url.lastPathComponent)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 12) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .disabled(!FileManager.default.fileExists(atPath: url.path))

                Button("Done") {
                    buildManager.reset()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { appeared = true }
    }
}

// MARK: - Failed

private struct FailedContent: View {
    let message: String
    @Environment(BuildManager.self) private var buildManager

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.red)

            VStack(spacing: 4) {
                Text("Build Failed")
                    .font(.headline)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            HStack(spacing: 12) {
                Button("Copy Error") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                }

                Button("Done") {
                    buildManager.reset()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
