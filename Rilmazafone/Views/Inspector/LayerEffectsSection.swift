import SwiftUI

struct LayerEffectsSection: View {
    let layer: BackgroundLayer

    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var variableBlurExpanded: Bool
    @State private var colorAdjustmentsExpanded: Bool
    @State private var vignetteExpanded: Bool
    @State private var bloomExpanded: Bool

    init(layer: BackgroundLayer) {
        self.layer = layer
        _variableBlurExpanded = State(initialValue: layer.variableBlur != nil)
        _colorAdjustmentsExpanded = State(initialValue: layer.colorAdjustments != nil)
        _vignetteExpanded = State(initialValue: layer.vignette != nil)
        _bloomExpanded = State(initialValue: layer.bloom != nil)
    }

    var body: some View {
        blurSection

        Section("Effects") {
            colorAdjustmentsGroup
            vignetteGroup
            bloomGroup
        }
        .onChange(of: expansionKey) { old, new in
            if old.layerID != new.layerID {
                // Selection switched while this Form stayed alive: re-seed
                // the disclosure state for the new layer without animating.
                variableBlurExpanded = new.variableBlur
                colorAdjustmentsExpanded = new.colorAdjustments
                vignetteExpanded = new.vignette
                bloomExpanded = new.bloom
            } else {
                let animation: Animation? = reduceMotion ? nil : .default
                if old.variableBlur != new.variableBlur { withAnimation(animation) { variableBlurExpanded = new.variableBlur } }
                if old.colorAdjustments != new.colorAdjustments { withAnimation(animation) { colorAdjustmentsExpanded = new.colorAdjustments } }
                if old.vignette != new.vignette { withAnimation(animation) { vignetteExpanded = new.vignette } }
                if old.bloom != new.bloom { withAnimation(animation) { bloomExpanded = new.bloom } }
            }
        }
    }

    /// One equatable fingerprint for everything that drives disclosure-group
    /// expansion, so a single handler can tell a selection switch (re-seed,
    /// no animation) apart from an effect toggle (animate).
    private struct EffectExpansionKey: Equatable {
        let layerID: UUID
        let variableBlur: Bool
        let colorAdjustments: Bool
        let vignette: Bool
        let bloom: Bool
    }

    private var expansionKey: EffectExpansionKey {
        EffectExpansionKey(
            layerID: layer.id,
            variableBlur: layer.variableBlur != nil,
            colorAdjustments: layer.colorAdjustments != nil,
            vignette: layer.vignette != nil,
            bloom: layer.bloom != nil,
        )
    }

    // MARK: - Blur

    private var blurSection: some View {
        let vb = layer.variableBlur ?? VariableBlurConfiguration()
        let isVariableOn = layer.variableBlur != nil

        return Section("Blur") {
            InspectorSliderRow(label: "Radius", value: blurRadiusBinding, range: 0 ... 50, unit: "px")

            DisclosureGroup(isExpanded: $variableBlurExpanded) {
                Group {
                    Picker("Mask", selection: variableBlurMaskTypeBinding(vb)) {
                        Text("Linear").tag(VariableBlurMaskType.linear)
                        Text("Radial").tag(VariableBlurMaskType.radial)
                    }
                    .pickerStyle(.segmented)

                    maskPreview(vb)

                    switch vb.maskType {
                    case .linear:
                        InspectorSliderRow(label: "Angle", value: variableBlurAngleBinding(vb), range: 0 ... 360, unit: "\u{00B0}")
                        InspectorSliderRow(label: "Start", value: variableBlurStartBinding(vb), range: 0 ... 1, unit: "", format: .percent)
                        InspectorSliderRow(label: "End", value: variableBlurEndBinding(vb), range: 0 ... 1, unit: "", format: .percent)
                    case .radial:
                        InspectorSliderRow(label: "Center X", value: variableBlurCenterXBinding(vb), range: 0 ... 1, unit: "", format: .percent)
                        InspectorSliderRow(label: "Center Y", value: variableBlurCenterYBinding(vb), range: 0 ... 1, unit: "", format: .percent)
                        InspectorSliderRow(label: "Start", value: variableBlurStartBinding(vb), range: 0 ... 1, unit: "", format: .percent)
                        InspectorSliderRow(label: "End", value: variableBlurEndBinding(vb), range: 0 ... 1, unit: "", format: .percent)
                    }
                }
                .disabled(!isVariableOn)
                .padding(.top, 16)
            } label: {
                Toggle("Variable", isOn: variableBlurEnabledBinding)
                    .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Mask Preview

    @ViewBuilder
    private func maskPreview(_ vb: VariableBlurConfiguration) -> some View {
        let sharpColor = Color.blue.opacity(0.15)
        let blurredColor = Color.blue.opacity(0.6)

        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)

            switch vb.maskType {
            case .linear:
                let angle = Angle(degrees: vb.angle)
                LinearGradient(
                    stops: [
                        .init(color: sharpColor, location: vb.startPoint),
                        .init(color: blurredColor, location: vb.endPoint),
                    ],
                    startPoint: linearStart(angle),
                    endPoint: linearEnd(angle),
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
            case .radial:
                RadialGradient(
                    stops: [
                        .init(color: sharpColor, location: vb.startPoint),
                        .init(color: blurredColor, location: vb.endPoint),
                    ],
                    center: UnitPoint(x: vb.centerX, y: vb.centerY),
                    startRadius: 0,
                    endRadius: 60,
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(.secondary.opacity(0.2))

            HStack {
                Text("Sharp")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Blurred")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 28)
    }

    private func linearStart(_ angle: Angle) -> UnitPoint {
        let rad = angle.radians
        return UnitPoint(
            x: 0.5 - cos(rad) * 0.5,
            y: 0.5 - sin(rad) * 0.5,
        )
    }

    private func linearEnd(_ angle: Angle) -> UnitPoint {
        let rad = angle.radians
        return UnitPoint(
            x: 0.5 + cos(rad) * 0.5,
            y: 0.5 + sin(rad) * 0.5,
        )
    }

    // MARK: - Color Adjustments

    private var colorAdjustmentsGroup: some View {
        let ca = layer.colorAdjustments ?? ColorAdjustments()
        let isOn = layer.colorAdjustments != nil

        return DisclosureGroup(isExpanded: $colorAdjustmentsExpanded) {
            Group {
                InspectorSliderRow(label: "Brightness", value: caBrightnessBinding(ca), range: -1 ... 1, unit: "")
                InspectorSliderRow(label: "Contrast", value: caContrastBinding(ca), range: 0 ... 2, unit: "")
                InspectorSliderRow(label: "Saturation", value: caSaturationBinding(ca), range: 0 ... 3, unit: "")
                InspectorSliderRow(label: "Hue Rotation", value: caHueBinding(ca), range: 0 ... 360, unit: "\u{00B0}")
                InspectorSliderRow(label: "Exposure", value: caExposureBinding(ca), range: -3 ... 3, unit: "EV")
            }
            .disabled(!isOn)
            .padding(.top, 16)
        } label: {
            Toggle("Color Adjustments", isOn: colorAdjustmentsEnabledBinding)
                .toggleStyle(.switch)
        }
    }

    // MARK: - Vignette

    private var vignetteGroup: some View {
        let v = layer.vignette ?? VignetteConfiguration()
        let isOn = layer.vignette != nil

        return DisclosureGroup(isExpanded: $vignetteExpanded) {
            Group {
                InspectorSliderRow(label: "Intensity", value: vignetteIntensityBinding(v), range: 0 ... 2, unit: "")
                InspectorSliderRow(label: "Radius", value: vignetteRadiusBinding(v), range: 0 ... 2, unit: "")
            }
            .disabled(!isOn)
            .padding(.top, 16)
        } label: {
            Toggle("Vignette", isOn: vignetteEnabledBinding)
                .toggleStyle(.switch)
        }
    }

    // MARK: - Bloom

    private var bloomGroup: some View {
        let b = layer.bloom ?? BloomConfiguration()
        let isOn = layer.bloom != nil

        return DisclosureGroup(isExpanded: $bloomExpanded) {
            Group {
                InspectorSliderRow(label: "Intensity", value: bloomIntensityBinding(b), range: 0 ... 1, unit: "")
                InspectorSliderRow(label: "Radius", value: bloomRadiusBinding(b), range: 0 ... 50, unit: "px")
            }
            .disabled(!isOn)
            .padding(.top, 16)
        } label: {
            Toggle("Bloom", isOn: bloomEnabledBinding)
                .toggleStyle(.switch)
        }
    }

    // MARK: - Blur Bindings

    private var blurRadiusBinding: Binding<Double> {
        Binding(
            get: { Double(layer.variableBlur?.radius ?? layer.blurRadius) },
            set: { newValue in
                if layer.variableBlur != nil {
                    var vb = layer.variableBlur!
                    vb.radius = newValue
                    document.setLayerVariableBlur(layer.id, to: vb, undoManager: undoManager)
                } else {
                    document.setBackgroundLayerBlur(layer.id, to: newValue, undoManager: undoManager)
                }
            },
        )
    }

    private var variableBlurEnabledBinding: Binding<Bool> {
        Binding(
            get: { layer.variableBlur != nil },
            set: { enabled in
                if enabled {
                    let radius = layer.blurRadius > 0 ? layer.blurRadius : 10
                    var config = VariableBlurConfiguration()
                    config.radius = radius
                    document.setLayerVariableBlur(layer.id, to: config, undoManager: undoManager)
                } else {
                    let radius = layer.variableBlur?.radius ?? layer.blurRadius
                    document.setLayerVariableBlur(layer.id, to: nil, undoManager: undoManager)
                    document.setBackgroundLayerBlur(layer.id, to: radius, undoManager: undoManager)
                }
            },
        )
    }

    // MARK: - Variable Blur Bindings

    private func updateVariableBlur(_ transform: (inout VariableBlurConfiguration) -> Void) {
        guard var vb = layer.variableBlur else { return }
        transform(&vb)
        document.setLayerVariableBlur(layer.id, to: vb, undoManager: undoManager)
    }

    private func variableBlurMaskTypeBinding(_ vb: VariableBlurConfiguration) -> Binding<VariableBlurMaskType> {
        Binding(
            get: { vb.maskType },
            set: { newType in updateVariableBlur { $0.maskType = newType } },
        )
    }

    private func variableBlurAngleBinding(_ vb: VariableBlurConfiguration) -> Binding<Double> {
        Binding(
            get: { vb.angle },
            set: { val in updateVariableBlur { $0.angle = val } },
        )
    }

    private func variableBlurCenterXBinding(_ vb: VariableBlurConfiguration) -> Binding<Double> {
        Binding(
            get: { vb.centerX },
            set: { val in updateVariableBlur { $0.centerX = val } },
        )
    }

    private func variableBlurCenterYBinding(_ vb: VariableBlurConfiguration) -> Binding<Double> {
        Binding(
            get: { vb.centerY },
            set: { val in updateVariableBlur { $0.centerY = val } },
        )
    }

    private func variableBlurStartBinding(_ vb: VariableBlurConfiguration) -> Binding<Double> {
        Binding(
            get: { vb.startPoint },
            set: { val in updateVariableBlur { $0.startPoint = val } },
        )
    }

    private func variableBlurEndBinding(_ vb: VariableBlurConfiguration) -> Binding<Double> {
        Binding(
            get: { vb.endPoint },
            set: { val in updateVariableBlur { $0.endPoint = val } },
        )
    }

    // MARK: - Enable/Disable Bindings

    private var colorAdjustmentsEnabledBinding: Binding<Bool> {
        Binding(
            get: { layer.colorAdjustments != nil },
            set: {
                document.setLayerColorAdjustments(
                    layer.id,
                    to: $0 ? ColorAdjustments() : nil,
                    undoManager: undoManager,
                )
            },
        )
    }

    private var vignetteEnabledBinding: Binding<Bool> {
        Binding(
            get: { layer.vignette != nil },
            set: {
                document.setLayerVignette(
                    layer.id,
                    to: $0 ? VignetteConfiguration() : nil,
                    undoManager: undoManager,
                )
            },
        )
    }

    private var bloomEnabledBinding: Binding<Bool> {
        Binding(
            get: { layer.bloom != nil },
            set: {
                document.setLayerBloom(
                    layer.id,
                    to: $0 ? BloomConfiguration() : nil,
                    undoManager: undoManager,
                )
            },
        )
    }

    // MARK: - Color Adjustments Bindings

    private func updateColorAdjustments(_ transform: (inout ColorAdjustments) -> Void) {
        guard var ca = layer.colorAdjustments else { return }
        transform(&ca)
        document.setLayerColorAdjustments(layer.id, to: ca, undoManager: undoManager)
    }

    private func caBrightnessBinding(_ ca: ColorAdjustments) -> Binding<Double> {
        Binding(
            get: { ca.brightness },
            set: { val in updateColorAdjustments { $0.brightness = val } },
        )
    }

    private func caContrastBinding(_ ca: ColorAdjustments) -> Binding<Double> {
        Binding(
            get: { ca.contrast },
            set: { val in updateColorAdjustments { $0.contrast = val } },
        )
    }

    private func caSaturationBinding(_ ca: ColorAdjustments) -> Binding<Double> {
        Binding(
            get: { ca.saturation },
            set: { val in updateColorAdjustments { $0.saturation = val } },
        )
    }

    private func caHueBinding(_ ca: ColorAdjustments) -> Binding<Double> {
        Binding(
            get: { ca.hueRotation },
            set: { val in updateColorAdjustments { $0.hueRotation = val } },
        )
    }

    private func caExposureBinding(_ ca: ColorAdjustments) -> Binding<Double> {
        Binding(
            get: { ca.exposure },
            set: { val in updateColorAdjustments { $0.exposure = val } },
        )
    }

    // MARK: - Vignette Bindings

    private func updateVignette(_ transform: (inout VignetteConfiguration) -> Void) {
        guard var v = layer.vignette else { return }
        transform(&v)
        document.setLayerVignette(layer.id, to: v, undoManager: undoManager)
    }

    private func vignetteIntensityBinding(_ v: VignetteConfiguration) -> Binding<Double> {
        Binding(
            get: { v.intensity },
            set: { val in updateVignette { $0.intensity = val } },
        )
    }

    private func vignetteRadiusBinding(_ v: VignetteConfiguration) -> Binding<Double> {
        Binding(
            get: { v.radius },
            set: { val in updateVignette { $0.radius = val } },
        )
    }

    // MARK: - Bloom Bindings

    private func updateBloom(_ transform: (inout BloomConfiguration) -> Void) {
        guard var b = layer.bloom else { return }
        transform(&b)
        document.setLayerBloom(layer.id, to: b, undoManager: undoManager)
    }

    private func bloomIntensityBinding(_ b: BloomConfiguration) -> Binding<Double> {
        Binding(
            get: { b.intensity },
            set: { val in updateBloom { $0.intensity = val } },
        )
    }

    private func bloomRadiusBinding(_ b: BloomConfiguration) -> Binding<Double> {
        Binding(
            get: { b.radius },
            set: { val in updateBloom { $0.radius = val } },
        )
    }
}
