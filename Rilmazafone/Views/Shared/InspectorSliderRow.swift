import AppKit
import SwiftUI

enum SliderValueFormat {
    case integer
    case decimal
    case percent
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
            Slider(value: $value, in: range)
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
