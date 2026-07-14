import SwiftUI

struct IconAppearanceSection: View {
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager

    @State private var showCustomIconSize = false
    @State private var showCustomTextSize = false
    @State private var showCustomGridSpacing = false

    private let iconSizePresets: [Int] = [32, 48, 64, 80, 96, 128, 160, 256, 512]
    private let textSizePresets: [Int] = [10, 11, 12, 13, 14, 16]
    private let gridSpacingPresets: [Int] = [50, 60, 80, 100]

    var body: some View {
        Section("Window Size") {
            LabeledContent("Size") {
                HStack(spacing: 6) {
                    Text("w")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", value: widthBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)

                    Text("h")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", value: heightBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)
                }
            }

            HStack(spacing: 6) {
                Spacer()
                presetButton("Compact", width: 540, height: 380, iconSize: 128, textSize: 12, gridSpacing: 90)
                presetButton("Standard", width: 660, height: 400, iconSize: 160, textSize: 13, gridSpacing: 100)
                presetButton("Large", width: 900, height: 500, iconSize: 256, textSize: 16, gridSpacing: 100)
            }
        }

        Section("Icon Appearance") {
            presetRow(
                label: "Icon Size",
                value: document.iconSize,
                presets: iconSizePresets,
                showCustom: $showCustomIconSize,
                setValue: { document.setIconSize($0, undoManager: undoManager) }
            )

            presetRow(
                label: "Text Size",
                value: document.textSize,
                presets: textSizePresets,
                showCustom: $showCustomTextSize,
                setValue: { document.setTextSize($0, undoManager: undoManager) }
            )

            gridSpacingRow

            Toggle(
                "Hide File Extensions",
                isOn: Binding(
                    get: { document.hideExtensions },
                    set: { document.setHideExtensions($0, undoManager: undoManager) }
                )
            )
            .toggleStyle(.switch)

            LabeledContent("Layout") {
                HStack(spacing: 6) {
                    Button {
                        document.distributeItemsHorizontally(undoManager: undoManager)
                    } label: {
                        Label("Distribute Horizontally", systemImage: "distribute.horizontal.center")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(document.items.count < 2)
                    .help("Space items evenly left to right")

                    Button {
                        document.centerItemsVertically(undoManager: undoManager)
                    } label: {
                        Label("Center Vertically", systemImage: "align.horizontal.center")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(document.items.isEmpty)
                    .help("Align all items to the vertical center")

                    Button {
                        document.distributeItemsVertically(undoManager: undoManager)
                    } label: {
                        Label("Distribute Vertically", systemImage: "distribute.vertical.center")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(document.items.count < 2)
                    .help("Space items evenly top to bottom")
                }
            }
        }
    }

    // MARK: - Grid Spacing

    private var gridSpacingRow: some View {
        LabeledContent("Grid Spacing") {
            HStack(spacing: 6) {
                Picker("", selection: gridSpacingModeBinding) {
                    Text("Auto").tag(true)
                    Text("Custom").tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize()

                if !document.isGridSpacingAuto {
                    Menu {
                        ForEach(gridSpacingPresets, id: \.self) { preset in
                            Button {
                                document.setGridSpacing(CGFloat(preset), undoManager: undoManager)
                                showCustomGridSpacing = false
                            } label: {
                                HStack {
                                    Text("\(preset) pt")
                                    if Int(document.gridSpacing) == preset,
                                       !showCustomGridSpacing {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                        Divider()
                        Button {
                            showCustomGridSpacing = true
                        } label: {
                            HStack {
                                Text("Custom\u{2026}")
                                if showCustomGridSpacing {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Text("\(Int(document.gridSpacing)) pt")
                                .monospacedDigit()
                            Image(systemName: "chevron.up.chevron.down")
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuIndicator(.hidden)

                    if showCustomGridSpacing {
                        TextField(
                            "",
                            value: Binding(
                                get: { Double(document.gridSpacing) },
                                set: { document.setGridSpacing(CGFloat($0), undoManager: undoManager) }
                            ),
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)

                        Text("pt")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var gridSpacingModeBinding: Binding<Bool> {
        Binding(
            get: { document.isGridSpacingAuto },
            set: { document.setGridSpacingAuto($0, undoManager: undoManager) }
        )
    }

    // MARK: - Window Size

    private var widthBinding: Binding<Double> {
        Binding(
            get: { document.window.width },
            set: {
                let clamped = min(max($0, 300), 1_200)
                document.setWindowWidth(clamped, undoManager: undoManager)
            }
        )
    }

    private var heightBinding: Binding<Double> {
        Binding(
            get: { document.window.height },
            set: {
                let clamped = min(max($0, 200), 800)
                document.setWindowHeight(clamped, undoManager: undoManager)
            }
        )
    }

    private func presetButton(
        _ label: String,
        width: CGFloat,
        height: CGFloat,
        iconSize: CGFloat,
        textSize: CGFloat,
        gridSpacing: CGFloat
    ) -> some View {
        Button(label) {
            undoManager?.beginUndoGrouping()
            document.setWindowSize(width: width, height: height, undoManager: undoManager)
            document.setIconSize(iconSize, undoManager: undoManager)
            document.setTextSize(textSize, undoManager: undoManager)
            document.setGridSpacing(gridSpacing, undoManager: undoManager)
            document.setGridSpacingAuto(true, undoManager: undoManager)
            undoManager?.endUndoGrouping()
            undoManager?.setActionName("Apply \(label) Preset")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    // MARK: - Preset Row

    private func presetRow(
        label: String,
        value: CGFloat,
        presets: [Int],
        showCustom: Binding<Bool>,
        setValue: @escaping (CGFloat) -> Void
    ) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(presets, id: \.self) { preset in
                        Button {
                            setValue(CGFloat(preset))
                            showCustom.wrappedValue = false
                        } label: {
                            HStack {
                                Text("\(preset) pt")
                                if Int(value) == preset, !showCustom.wrappedValue {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    Divider()
                    Button {
                        showCustom.wrappedValue = true
                    } label: {
                        HStack {
                            Text("Custom\u{2026}")
                            if showCustom.wrappedValue {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text("\(Int(value)) pt")
                            .monospacedDigit()
                        Image(systemName: "chevron.up.chevron.down")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                    }
                }
                .menuIndicator(.hidden)

                if showCustom.wrappedValue {
                    TextField(
                        "",
                        value: Binding(
                            get: { Double(value) },
                            set: { setValue(CGFloat($0)) }
                        ),
                        format: .number
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 55)

                    Text("pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
