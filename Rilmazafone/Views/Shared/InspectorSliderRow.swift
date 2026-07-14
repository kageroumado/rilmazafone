import AppKit
import SwiftUI

enum SliderValueFormat {
    case integer
    case decimal
    case percent
}

/// A `Slider` that coalesces each scrub into one undoable action.
///
/// The document mutators behind inspector bindings register an undo action
/// per write, so a bare `Slider` pushes one undo step per drag tick and
/// Cmd+Z replays the scrub one imperceptible increment at a time. Interim
/// drag values write through the binding with undo registration disabled
/// (keeping the live canvas preview), and on release the value is replayed
/// start → end with registration enabled, producing exactly one undo step
/// for the whole scrub.
struct UndoCoalescingSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    @Environment(\.undoManager) private var undoManager
    @State private var scrubStartValue: Double?

    var body: some View {
        Slider(value: $value, in: range, onEditingChanged: editingChanged)
            .onDisappear {
                // A scrub interrupted by view removal must not leave the
                // manager's registration counter unbalanced.
                if scrubStartValue != nil {
                    undoManager?.enableUndoRegistration()
                    scrubStartValue = nil
                }
            }
    }

    private func editingChanged(_ editing: Bool) {
        guard let undoManager else { return }
        if editing {
            guard scrubStartValue == nil else { return }
            scrubStartValue = value
            undoManager.disableUndoRegistration()
        } else {
            guard let start = scrubStartValue else { return }
            scrubStartValue = nil
            undoManager.enableUndoRegistration()
            guard start != value else { return }
            let end = value
            undoManager.disableUndoRegistration()
            value = start
            undoManager.enableUndoRegistration()
            value = end
        }
    }
}

struct InspectorSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit: String = ""
    var format: SliderValueFormat = .integer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                Spacer()
                formattedValue
            }
            UndoCoalescingSlider(value: $value, range: range)
        }
    }

    @ViewBuilder
    private var formattedValue: some View {
        switch format {
        case .integer:
            Text("\(Int(value)) \(unit)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .decimal:
            Text(String(format: "%.1f %@", value, unit))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        case .percent:
            Text("\(Int(value * 100))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Alert Utility

extension NSAlert {
    /// Shows a modal error alert with the given message and detail.
    static func showError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}
