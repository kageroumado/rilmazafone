import SwiftUI

struct GradientEditor: View {
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager

    private var gradient: GradientConfiguration {
        document.configuration.background.gradient ?? GradientConfiguration()
    }

    var body: some View {
        gradientPreview

        Picker("Type", selection: typeBinding) {
            Text("Linear").tag(GradientType.linear)
            Text("Radial").tag(GradientType.radial)
        }
        .pickerStyle(.segmented)

        ColorPicker("Start Color", selection: startColorBinding, supportsOpacity: false)
        ColorPicker("End Color", selection: endColorBinding, supportsOpacity: false)

        switch gradient.type {
        case .linear:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Angle")
                    Spacer()
                    Text("\(Int(gradient.angle))\u{00B0}")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: angleBinding, in: 0 ... 360)
            }

        case .radial:
            LabeledContent("Center") {
                HStack(spacing: 4) {
                    Text("x")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", value: centerXBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 45)

                    Text("y")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", value: centerYBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 45)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Start Radius")
                    Spacer()
                    Text(String(format: "%.0f%%", gradient.startRadius * 100))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: startRadiusBinding, in: 0 ... 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("End Radius")
                    Spacer()
                    Text(String(format: "%.0f%%", gradient.endRadius * 100))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: endRadiusBinding, in: 0 ... 2)
            }
        }
    }

    // MARK: - Preview

    private var gradientPreview: some View {
        let stops = gradient.stops
            .sorted { $0.location < $1.location }
            .map { stop in
                Gradient.Stop(
                    color: Color(red: stop.color.red, green: stop.color.green, blue: stop.color.blue),
                    location: stop.location
                )
            }

        return Group {
            switch gradient.type {
            case .linear:
                let radians = gradient.angle * .pi / 180
                let start = UnitPoint(
                    x: 0.5 + cos(radians + .pi) * 0.5,
                    y: 0.5 + sin(radians + .pi) * 0.5
                )
                let end = UnitPoint(
                    x: 0.5 + cos(radians) * 0.5,
                    y: 0.5 + sin(radians) * 0.5
                )
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(stops: stops, startPoint: start, endPoint: end))
            case .radial:
                RoundedRectangle(cornerRadius: 6)
                    .fill(RadialGradient(
                        stops: stops,
                        center: UnitPoint(x: gradient.centerX, y: gradient.centerY),
                        startRadius: gradient.startRadius * 100,
                        endRadius: gradient.endRadius * 100
                    ))
            }
        }
        .frame(height: 40)
    }

    // MARK: - Helpers

    private func update(_ transform: (inout GradientConfiguration) -> Void) {
        var grad = gradient
        transform(&grad)
        document.setGradientConfiguration(to: grad, undoManager: undoManager)
    }

    // MARK: - Bindings

    private var typeBinding: Binding<GradientType> {
        Binding(
            get: { gradient.type },
            set: { newType in update { $0.type = newType } }
        )
    }

    private var startColorBinding: Binding<Color> {
        Binding(
            get: {
                guard gradient.stops.count >= 1 else { return .blue }
                return gradient.stops[0].color.swiftUIColor
            },
            set: { newColor in
                guard let rgb = RGBColor(swiftUIColor: newColor) else { return }
                update { grad in
                    if grad.stops.count >= 1 {
                        grad.stops[0].color = rgb
                    }
                }
            }
        )
    }

    private var endColorBinding: Binding<Color> {
        Binding(
            get: {
                guard gradient.stops.count >= 2 else { return .pink }
                return gradient.stops[1].color.swiftUIColor
            },
            set: { newColor in
                guard let rgb = RGBColor(swiftUIColor: newColor) else { return }
                update { grad in
                    if grad.stops.count >= 2 {
                        grad.stops[1].color = rgb
                    }
                }
            }
        )
    }

    private var angleBinding: Binding<Double> {
        Binding(
            get: { gradient.angle },
            set: { val in update { $0.angle = val } }
        )
    }

    private var centerXBinding: Binding<Double> {
        Binding(
            get: { gradient.centerX },
            set: { val in update { $0.centerX = min(max(val, 0), 1) } }
        )
    }

    private var centerYBinding: Binding<Double> {
        Binding(
            get: { gradient.centerY },
            set: { val in update { $0.centerY = min(max(val, 0), 1) } }
        )
    }

    private var startRadiusBinding: Binding<Double> {
        Binding(
            get: { gradient.startRadius },
            set: { val in update { $0.startRadius = val } }
        )
    }

    private var endRadiusBinding: Binding<Double> {
        Binding(
            get: { gradient.endRadius },
            set: { val in update { $0.endRadius = val } }
        )
    }
}
