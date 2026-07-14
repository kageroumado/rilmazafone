import SwiftUI

/// Aggregate toolbar chip for label legibility warnings.
///
/// Hidden while there are no warnings. Clicking it opens a popover listing each
/// flagged item with the affected appearance mode and a one-click "Add Panel"
/// remediation that installs a sensible default panel behind the label (undoable).
struct LegibilityWarningChip: View {
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager
    @State private var isPopoverPresented = false

    private var flaggedItems: [(item: CanvasItem, modes: [LabelAppearanceMode])] {
        document.items.compactMap { item in
            let modes = document.legibilityModes(for: item.id)
            return modes.isEmpty ? nil : (item, modes)
        }
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
                "Finder colors labels black in Light Mode and white in Dark Mode, "
                    + "but a DMG background never changes with appearance.",
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            ForEach(flaggedItems, id: \.item.id) { flagged in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(flagged.item.label)
                            .lineLimit(1)
                        Text(modesDescription(flagged.modes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Add Panel") {
                        addRemediationPanel(for: flagged.item, modes: flagged.modes)
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

    private func modesDescription(_ modes: [LabelAppearanceMode]) -> String {
        "May be unreadable in " + modes.map(\.displayName).joined(separator: " and ")
    }

    // MARK: - Remediation

    /// Default remediation panel constants: a blurred glass panel whose tint is
    /// chosen from the flagged modes so the label region lands at a luminance
    /// readable in both appearances.
    private enum RemediationPanel {
        static let opacity: CGFloat = 0.5
        static let blurRadius: CGFloat = 20
        /// Dark-mode warning means the backdrop is too bright for white labels →
        /// darken with black glass. Light-only warnings get white glass.
        static let darkeningColor = RGBColor(red: 0, green: 0, blue: 0)
        static let lighteningColor = RGBColor(red: 1, green: 1, blue: 1)
        /// Both modes flagged (busy mid-luminance backdrop) → pull toward mid-gray,
        /// which clears 3.9:1 against both black and white labels while the blur
        /// removes the variance penalty.
        static let neutralColor = RGBColor(red: 0.5, green: 0.5, blue: 0.5)
    }

    private func addRemediationPanel(for item: CanvasItem, modes: [LabelAppearanceMode]) {
        let color: RGBColor = if modes.count > 1 {
            RemediationPanel.neutralColor
        } else if modes.contains(.dark) {
            RemediationPanel.darkeningColor
        } else {
            RemediationPanel.lighteningColor
        }

        let panel = ItemBackground(
            enabled: true,
            color: color,
            opacity: RemediationPanel.opacity,
            blurRadius: RemediationPanel.blurRadius,
        )
        document.setItemBackground(item.id, to: panel, undoManager: undoManager)
    }
}
