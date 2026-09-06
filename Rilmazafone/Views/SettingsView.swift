import SwiftUI

/// App settings: the new-document behavior, and — on the GitHub build — a
/// version line with a manual update check.
struct SettingsView: View {
    @AppStorage(NewDocumentPolicy.showsChooserDefaultsKey) private var showsChooser = true

    private enum Layout {
        static let padding: CGFloat = 20
        static let minimumWidth: CGFloat = 360
    }

    var body: some View {
        Form {
            Picker("For New Documents:", selection: $showsChooser) {
                Text("Show Template Chooser").tag(true)
                Text("Create Blank Document").tag(false)
            }
            .pickerStyle(.radioGroup)

            #if !APPSTORE
                UpdateCheckRow()
            #endif
        }
        .padding(Layout.padding)
        .frame(minWidth: Layout.minimumWidth)
    }
}

#if !APPSTORE
    /// The version line plus a "Check for Updates" button that queries GitHub
    /// and offers the releases page — tooling points the way, it doesn't
    /// self-update.
    private struct UpdateCheckRow: View {
        @State private var status: Status = .idle

        private enum Status: Equatable {
            case idle
            case checking
            case upToDate
            case available(latest: String, page: URL)
            case failed
        }

        var body: some View {
            LabeledContent("Version") {
                HStack(spacing: 8) {
                    Text(UpdateCheck.currentVersion)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    statusView
                    Spacer()
                    Button("Check for Updates") { check() }
                        .controlSize(.small)
                        .disabled(status == .checking)
                }
            }
        }

        @ViewBuilder
        private var statusView: some View {
            switch status {
            case .idle:
                EmptyView()
            case .checking:
                ProgressView().controlSize(.small)
            case .upToDate:
                Label("Up to date", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.green)
            case let .available(latest, page):
                Link(destination: page) {
                    Label("\(latest) available", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                }
            case .failed:
                Label("Check failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
            }
        }

        private func check() {
            status = .checking
            Task {
                guard let result = await UpdateCheck.fetchLatest() else {
                    status = .failed
                    return
                }
                status = result.updateAvailable
                    ? .available(latest: result.latest, page: result.pageURL)
                    : .upToDate
            }
        }
    }
#endif
