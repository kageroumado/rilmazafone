import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ItemInspector: View {
    let item: CanvasItem

    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager
    @State private var cachedIcon: NSImage?
    @State private var backgroundExpanded: Bool
    @State private var shadowExpanded: Bool
    @State private var bevelExpanded: Bool

    init(item: CanvasItem) {
        self.item = item
        _backgroundExpanded = State(initialValue: item.background?.enabled ?? false)
        _shadowExpanded = State(initialValue: item.background?.shadow?.enabled ?? false)
        _bevelExpanded = State(initialValue: item.background?.bevel?.enabled ?? false)
    }

    /// One equatable fingerprint for everything that drives disclosure-group
    /// expansion, so a single handler can tell a selection switch (re-seed,
    /// no animation) apart from an effect toggle (animate).
    private struct EffectExpansionKey: Equatable {
        let itemID: UUID
        let background: Bool
        let shadow: Bool
        let bevel: Bool
    }

    private var expansionKey: EffectExpansionKey {
        EffectExpansionKey(
            itemID: item.id,
            background: item.background?.enabled ?? false,
            shadow: item.background?.shadow?.enabled ?? false,
            bevel: item.background?.bevel?.enabled ?? false,
        )
    }

    private var windowWidth: CGFloat {
        document.window.width
    }
    private var windowHeight: CGFloat {
        document.window.height
    }

    var body: some View {
        Section {
            // Header with icon and editable name
            HStack(spacing: 10) {
                itemIcon
                    .frame(width: 32, height: 32)

                TextField("Name", text: nameBinding)
                    .textFieldStyle(.roundedBorder)
            }

            // Position
            LabeledContent("Position") {
                HStack(spacing: 4) {
                    Text("x")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", value: xBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)

                    Text("y")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("", value: yBinding, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 55)
                }
            }

            // Behavior — copy vs symlink
            if item.kind != .applicationsSymlink {
                Picker("Behavior", selection: linkTypeBinding) {
                    Text("Copy to volume").tag(ItemLinkType.copy)
                    Text("Create symlink").tag(ItemLinkType.symlink)
                }
            } else {
                LabeledContent("Behavior") {
                    Text("Symlink to /Applications")
                        .foregroundStyle(.secondary)
                }
            }

            // Source / target path
            if item.kind != .applicationsSymlink {
                if item.linkType == .symlink {
                    LabeledContent("Target") {
                        VStack(alignment: .trailing, spacing: 4) {
                            TextField("", text: symlinkTargetBinding)
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)

                            if item.sourcePath == nil || item.sourcePath?.isEmpty == true {
                                Label("No target set", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                } else if item.isEmbedded {
                    LabeledContent("Source") {
                        VStack(alignment: .trailing, spacing: 4) {
                            Label("Embedded in document", systemImage: "doc.zipper")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button("Replace\u{2026}") {
                                relinkSource()
                            }
                            .controlSize(.small)
                        }
                    }
                } else {
                    LabeledContent("Source") {
                        VStack(alignment: .trailing, spacing: 4) {
                            if let path = item.sourcePath {
                                Text(abbreviatedPath(path))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                    .help(path)

                                if isSourceMissing {
                                    Label("File not found", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            } else {
                                Text("None")
                                    .foregroundStyle(.tertiary)
                            }

                            Button(isSourceMissing ? "Locate\u{2026}" : "Choose\u{2026}") {
                                relinkSource()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .task(id: item.iconCacheKey(isSourceMissing: isSourceMissing)) {
            cachedIcon = CanvasItem.resolveIcon(for: item, documentURL: document.fileURL)
        }

        Section("Effects") {
            backgroundGroup
            shadowGroup
                .disabled(!(item.background?.enabled ?? false))
            bevelGroup

            if document.items.count > 1 {
                Button("Apply to All") {
                    document.copyItemBackgroundToAll(item.id, undoManager: undoManager)
                }
                .controlSize(.small)
            }

            if item.background != nil {
                Button("Reset Effects", role: .destructive) {
                    document.setItemBackground(item.id, to: nil, undoManager: undoManager)
                }
                .controlSize(.small)
            }
        }
        .onChange(of: expansionKey) { old, new in
            if old.itemID != new.itemID {
                // Selection switched while this Form stayed alive: re-seed
                // the disclosure state for the new item without animating.
                backgroundExpanded = new.background
                shadowExpanded = new.shadow
                bevelExpanded = new.bevel
            } else {
                if old.background != new.background { withAnimation { backgroundExpanded = new.background } }
                if old.shadow != new.shadow { withAnimation { shadowExpanded = new.shadow } }
                if old.bevel != new.bevel { withAnimation { bevelExpanded = new.bevel } }
            }
        }
    }

    // MARK: - Background Group

    private var backgroundGroup: some View {
        let bg = item.background ?? ItemBackground()
        let isOn = item.background?.enabled ?? false

        return DisclosureGroup(isExpanded: $backgroundExpanded) {
            Group {
                ColorPicker(
                    "Color",
                    selection: bgColorBinding(bg),
                    supportsOpacity: false,
                )

                InspectorSliderRow(label: "Opacity", value: bgOpacityBinding(bg), range: 0 ... 1, format: .percent)
                InspectorSliderRow(label: "Corner Radius", value: bgCornerRadiusBinding(bg), range: 0 ... 40, unit: "px")
                InspectorSliderRow(label: "Padding", value: bgPaddingBinding(bg), range: 0 ... 60, unit: "px")
                InspectorSliderRow(label: "Blur", value: bgBlurBinding(bg), range: 0 ... 50, unit: "px")

                if bg.blurRadius > 0 {
                    InspectorSliderRow(label: "Edge Fade", value: bgBlurFeatherBinding(bg), range: 0 ... 1, format: .percent)
                }

                Picker("Blend Mode", selection: bgBlendModeBinding(bg)) {
                    ForEach(ItemBlendMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
            .disabled(!isOn)
            .padding(.top, 16)
        } label: {
            Toggle("Background", isOn: backgroundEnabledBinding)
                .toggleStyle(.switch)
        }
    }

    // MARK: - Shadow Group

    private var shadowGroup: some View {
        let shadow = item.background?.shadow ?? ShadowConfiguration()
        let isOn = item.background?.shadow?.enabled ?? false

        return DisclosureGroup(isExpanded: $shadowExpanded) {
            Group {
                ColorPicker("Color", selection: shadowColorBinding(shadow), supportsOpacity: false)

                InspectorSliderRow(label: "Opacity", value: shadowOpacityBinding(shadow), range: 0 ... 1, format: .percent)
                InspectorSliderRow(label: "Blur", value: shadowRadiusBinding(shadow), range: 0 ... 30, unit: "px")

                LabeledContent("Offset") {
                    HStack(spacing: 4) {
                        Text("x")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("", value: shadowOffsetXBinding(shadow), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 45)

                        Text("y")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("", value: shadowOffsetYBinding(shadow), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 45)
                    }
                }
            }
            .disabled(!isOn)
            .padding(.top, 16)
        } label: {
            Toggle("Shadow", isOn: shadowEnabledBinding)
                .toggleStyle(.switch)
        }
    }

    // MARK: - Bevel Group

    private var bevelGroup: some View {
        let bevel = item.background?.bevel ?? BevelConfiguration()
        let isOn = item.background?.bevel?.enabled ?? false

        return DisclosureGroup(isExpanded: $bevelExpanded) {
            Group {
                InspectorSliderRow(label: "Depth", value: bevelDepthBinding(bevel), range: 1 ... 20, unit: "px")
                InspectorSliderRow(label: "Light Angle", value: bevelLightAngleBinding(bevel), range: 0 ... 360, unit: "\u{00B0}")
                InspectorSliderRow(label: "Intensity", value: bevelIntensityBinding(bevel), range: 0 ... 1, format: .decimal)
            }
            .disabled(!isOn)
            .padding(.top, 16)
        } label: {
            Toggle("Bevel", isOn: bevelEnabledBinding)
                .toggleStyle(.switch)
        }
    }

    // MARK: - Path Helpers

    private func abbreviatedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private var isSourceMissing: Bool {
        document.missingSourceIDs.contains(item.id)
    }

    private func relinkSource() {
        guard let url = SourceLocatePanel.present(for: item) else { return }
        Task {
            await document.relinkItem(item.id, to: url, undoManager: undoManager)
        }
    }

    // MARK: - Icon

    @ViewBuilder
    private var itemIcon: some View {
        if let nsImage = cachedIcon {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Bindings

    private var nameBinding: Binding<String> {
        Binding(
            get: { item.label },
            set: { document.setItemLabel(item.id, to: $0, undoManager: undoManager) },
        )
    }

    private var linkTypeBinding: Binding<ItemLinkType> {
        Binding(
            get: { item.linkType },
            set: { document.setItemLinkType(item.id, to: $0, undoManager: undoManager) },
        )
    }

    private var symlinkTargetBinding: Binding<String> {
        Binding(
            get: { item.sourcePath ?? "" },
            set: { document.setItemSourcePath(item.id, to: $0.isEmpty ? nil : $0, undoManager: undoManager) },
        )
    }

    private var xBinding: Binding<Double> {
        Binding(
            get: { item.position.x },
            set: {
                let clamped = min(max($0, 0), windowWidth)
                document.moveItem(item.id, to: CGPoint(x: clamped, y: item.position.y), undoManager: undoManager)
            },
        )
    }

    private var yBinding: Binding<Double> {
        Binding(
            get: { item.position.y },
            set: {
                let clamped = min(max($0, 0), windowHeight)
                document.moveItem(item.id, to: CGPoint(x: item.position.x, y: clamped), undoManager: undoManager)
            },
        )
    }

    private var iconName: String {
        switch item.kind {
        case .app: "app.dashed"
        case .applicationsSymlink: "folder"
        case .file: "doc"
        case .folder: "folder"
        }
    }

    // MARK: - Background Bindings

    private var backgroundEnabledBinding: Binding<Bool> {
        Binding(
            get: { item.background?.enabled ?? false },
            set: { enabled in
                if enabled {
                    if item.background != nil {
                        document.setItemBackgroundEnabled(item.id, true, undoManager: undoManager)
                    } else {
                        document.setItemBackground(item.id, to: ItemBackground(), undoManager: undoManager)
                    }
                } else {
                    document.setItemBackgroundEnabled(item.id, false, undoManager: undoManager)
                }
            },
        )
    }

    private func updateBg(_ transform: (inout ItemBackground) -> Void) {
        document.updateItemBackground(item.id, with: transform, undoManager: undoManager)
    }

    private func bgColorBinding(_ bg: ItemBackground) -> Binding<Color> {
        Binding(
            get: { bg.color.swiftUIColor },
            set: { newColor in
                guard let rgb = RGBColor(swiftUIColor: newColor) else { return }
                updateBg { $0.color = rgb }
            },
        )
    }

    private func bgOpacityBinding(_ bg: ItemBackground) -> Binding<Double> {
        Binding(get: { bg.opacity }, set: { val in updateBg { $0.opacity = val } })
    }

    private func bgCornerRadiusBinding(_ bg: ItemBackground) -> Binding<Double> {
        Binding(get: { bg.cornerRadius }, set: { val in updateBg { $0.cornerRadius = val } })
    }

    private func bgPaddingBinding(_ bg: ItemBackground) -> Binding<Double> {
        Binding(get: { bg.padding }, set: { val in updateBg { $0.padding = val } })
    }

    private func bgBlurBinding(_ bg: ItemBackground) -> Binding<Double> {
        Binding(get: { bg.blurRadius }, set: { val in updateBg { $0.blurRadius = val } })
    }

    private func bgBlurFeatherBinding(_ bg: ItemBackground) -> Binding<Double> {
        Binding(get: { bg.blurFeather }, set: { val in updateBg { $0.blurFeather = val } })
    }

    private func bgBlendModeBinding(_ bg: ItemBackground) -> Binding<ItemBlendMode> {
        Binding(
            get: { bg.blendMode },
            set: { val in updateBg { $0.blendMode = val } },
        )
    }

    // MARK: - Shadow Bindings

    private var shadowEnabledBinding: Binding<Bool> {
        Binding(
            get: { item.background?.shadow?.enabled ?? false },
            set: { enabled in
                if enabled {
                    if item.background == nil {
                        var bg = ItemBackground()
                        bg.enabled = false
                        bg.shadow = ShadowConfiguration()
                        document.setItemBackground(item.id, to: bg, undoManager: undoManager)
                    } else if var shadow = item.background?.shadow {
                        shadow.enabled = true
                        document.setItemShadow(item.id, to: shadow, undoManager: undoManager)
                    } else {
                        document.setItemShadow(item.id, to: ShadowConfiguration(), undoManager: undoManager)
                    }
                } else {
                    if var shadow = item.background?.shadow {
                        shadow.enabled = false
                        document.setItemShadow(item.id, to: shadow, undoManager: undoManager)
                    }
                }
            },
        )
    }

    private func updateShadow(_ transform: (inout ShadowConfiguration) -> Void) {
        guard var shadow = item.background?.shadow else { return }
        transform(&shadow)
        document.setItemShadow(item.id, to: shadow, undoManager: undoManager)
    }

    private func shadowColorBinding(_ shadow: ShadowConfiguration) -> Binding<Color> {
        Binding(
            get: { shadow.color.swiftUIColor },
            set: { newColor in
                guard let rgb = RGBColor(swiftUIColor: newColor) else { return }
                updateShadow { $0.color = rgb }
            },
        )
    }

    private func shadowOpacityBinding(_ shadow: ShadowConfiguration) -> Binding<Double> {
        Binding(
            get: { shadow.opacity },
            set: { val in updateShadow { $0.opacity = val } },
        )
    }

    private func shadowRadiusBinding(_ shadow: ShadowConfiguration) -> Binding<Double> {
        Binding(
            get: { shadow.radius },
            set: { val in updateShadow { $0.radius = val } },
        )
    }

    private func shadowOffsetXBinding(_ shadow: ShadowConfiguration) -> Binding<Double> {
        Binding(
            get: { shadow.offsetX },
            set: { val in updateShadow { $0.offsetX = val } },
        )
    }

    private func shadowOffsetYBinding(_ shadow: ShadowConfiguration) -> Binding<Double> {
        Binding(
            get: { shadow.offsetY },
            set: { val in updateShadow { $0.offsetY = val } },
        )
    }

    // MARK: - Bevel Bindings

    private var bevelEnabledBinding: Binding<Bool> {
        Binding(
            get: { item.background?.bevel?.enabled ?? false },
            set: { enabled in
                if enabled {
                    if item.background == nil {
                        var bg = ItemBackground()
                        bg.enabled = false
                        bg.bevel = BevelConfiguration()
                        document.setItemBackground(item.id, to: bg, undoManager: undoManager)
                    } else if var bevel = item.background?.bevel {
                        bevel.enabled = true
                        document.setItemBevel(item.id, to: bevel, undoManager: undoManager)
                    } else {
                        document.setItemBevel(item.id, to: BevelConfiguration(), undoManager: undoManager)
                    }
                } else {
                    if var bevel = item.background?.bevel {
                        bevel.enabled = false
                        document.setItemBevel(item.id, to: bevel, undoManager: undoManager)
                    }
                }
            },
        )
    }

    private func updateBevel(_ transform: (inout BevelConfiguration) -> Void) {
        guard var bevel = item.background?.bevel else { return }
        transform(&bevel)
        document.setItemBevel(item.id, to: bevel, undoManager: undoManager)
    }

    private func bevelDepthBinding(_ bevel: BevelConfiguration) -> Binding<Double> {
        Binding(
            get: { bevel.depth },
            set: { val in updateBevel { $0.depth = val } },
        )
    }

    private func bevelLightAngleBinding(_ bevel: BevelConfiguration) -> Binding<Double> {
        Binding(
            get: { bevel.lightAngle },
            set: { val in updateBevel { $0.lightAngle = val } },
        )
    }

    private func bevelIntensityBinding(_ bevel: BevelConfiguration) -> Binding<Double> {
        Binding(
            get: { bevel.intensity },
            set: { val in updateBevel { $0.intensity = val } },
        )
    }
}
