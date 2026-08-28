import SwiftUI

/// Aggregate toolbar chip for label legibility warnings.
///
/// Hidden while there are no warnings. Clicking it opens a popover listing each
/// flagged item with a one-click "Add Panel" remediation that installs a sensible
/// default panel behind the label (undoable).
struct LegibilityWarningChip: View {
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager
    @State private var isPopoverPresented = false

    private var flaggedItems: [CanvasItem] {
        document.items.filter { document.isLabelIllegible($0.id) }
    }

    var body: some View {
        if let summary = document.legibilitySummary {
            Button {
                isPopoverPresented.toggle()
            } label: {
                Label(summary, systemImage: "textformat.abc")
                    .labelStyle(.titleAndIcon)
            }
            .foregroundStyle(.orange)
            .help("Some labels may be hard to read against the background. Click for details.")
            .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
                popoverContent
            }
        }
    }

    // MARK: - Popover

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Label Legibility")
                .font(.headline)

            Text(
                "Finder draws these labels dark whatever the system appearance: "
                    + "a window with a background picture keeps its Light Mode "
                    + "rendering. A dark background stays hard to read in both.",
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            ForEach(flaggedItems) { item in
                HStack(spacing: 8) {
                    Text(item.label)
                        .lineLimit(1)

                    Spacer()

                    Button("Add Panel") {
                        addRemediationPanel(for: item)
                    }
                    .controlSize(.small)
                    .help(
                        "Add a glass panel behind this item's label to restore contrast. Undoable.",
                    )
                }
            }

            Divider()

            Text(
                "Fixes: add a glass or solid panel behind the label, "
                    + "reposition the item, or adjust the background.",
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
    }

    // MARK: - Remediation

    /// Default remediation panel: blurred white glass. The label is dark whatever the
    /// appearance, so lightening the region behind it is the only direction that helps.
    private enum RemediationPanel {
        static let opacity: CGFloat = 0.5
        static let blurRadius: CGFloat = 20
        static let color = RGBColor(red: 1, green: 1, blue: 1)
    }

    private func addRemediationPanel(for item: CanvasItem) {
        let panel = ItemBackground(
            enabled: true,
            color: RemediationPanel.color,
            opacity: RemediationPanel.opacity,
            blurRadius: RemediationPanel.blurRadius,
        )
        document.setItemBackground(item.id, to: panel, undoManager: undoManager)
    }
}
