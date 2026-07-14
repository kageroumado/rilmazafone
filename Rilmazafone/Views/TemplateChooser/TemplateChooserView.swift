import AppKit
import SwiftUI

// MARK: - Window Size Presets

/// The chooser's window-size footer control. `.templateDefault` keeps the
/// selected template's own size (no override); the presets and custom values
/// override it.
enum WindowSizeChoice: Hashable {
    case templateDefault
    case compact
    case standard
    case large
    case custom
}

nonisolated enum WindowSizePreset {
    static let compact = CGSize(width: 500, height: 340)
    static let standard = CGSize(width: 660, height: 400)
    static let large = CGSize(width: 800, height: 500)

    static let minimumWidth: CGFloat = 320
    static let minimumHeight: CGFloat = 200
    static let maximumWidth: CGFloat = 2_560
    static let maximumHeight: CGFloat = 1_600
}

// MARK: - Chooser View

/// Pages-style template gallery: Blank first (default-selected), then bundled,
/// then user templates. Double-click or Return creates; Esc cancels.
struct TemplateChooserView: View {
    let registry: TemplateRegistry
    let onCreate: (TemplateChooserSelection, CGSize?) -> Void
    let onCancel: () -> Void

    @State private var selection: TemplateChooserSelection = .blank
    @State private var sizeChoice: WindowSizeChoice = .templateDefault
    @State private var customWidth: Double = Double(WindowSizePreset.standard.width)
    @State private var customHeight: Double = Double(WindowSizePreset.standard.height)
    @AppStorage(NewDocumentPolicy.showsChooserDefaultsKey) private var showsChooser = true

    private enum Layout {
        static let windowWidth: CGFloat = 700
        static let windowHeight: CGFloat = 480
        static let gridSpacing: CGFloat = 20
        static let gridPadding: CGFloat = 24
        static let tileWidth: CGFloat = 148
        static let customFieldWidth: CGFloat = 52
    }

    var body: some View {
        VStack(spacing: 0) {
            gallery
            Divider()
            footer
        }
        .frame(width: Layout.windowWidth, height: Layout.windowHeight)
        .onChange(of: selection) {
            sizeChoice = .templateDefault
        }
        .onChange(of: sizeChoice) {
            if sizeChoice == .custom {
                let seed = resolvedWindowSize
                customWidth = Double(seed.width)
                customHeight = Double(seed.height)
            }
        }
    }

    // MARK: Gallery

    private var gallery: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(
                    .adaptive(minimum: Layout.tileWidth),
                    spacing: Layout.gridSpacing
                )],
                spacing: Layout.gridSpacing
            ) {
                TemplateTile(
                    title: "Blank",
                    entry: nil,
                    registry: registry,
                    isSelected: selection == .blank,
                    onSelect: { selection = .blank },
                    onCreate: { createSelection(.blank) }
                )
                ForEach(registry.bundled) { entry in
                    tile(for: entry)
                }
                ForEach(registry.user) { entry in
                    tile(for: entry)
                }
            }
            .padding(Layout.gridPadding)
        }
    }

    private func tile(for entry: TemplateEntry) -> some View {
        TemplateTile(
            title: entry.name,
            entry: entry,
            registry: registry,
            isSelected: selection == .template(entry),
            onSelect: { selection = .template(entry) },
            onCreate: { createSelection(.template(entry)) }
        )
    }

    private func createSelection(_ newSelection: TemplateChooserSelection) {
        selection = newSelection
        onCreate(newSelection, windowSizeOverride)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("Don't show this dialog again", isOn: dontShowAgainBinding)
                .controlSize(.small)

            Spacer()

            sizeControl

            Button("Cancel") {
                onCancel()
            }
            .keyboardShortcut(.cancelAction)

            Button("Create") {
                onCreate(selection, windowSizeOverride)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var sizeControl: some View {
        Picker("Window Size:", selection: $sizeChoice) {
            Text(templateDefaultLabel).tag(WindowSizeChoice.templateDefault)
            Divider()
            Text(presetLabel("Compact", WindowSizePreset.compact)).tag(WindowSizeChoice.compact)
            Text(presetLabel("Standard", WindowSizePreset.standard)).tag(WindowSizeChoice.standard)
            Text(presetLabel("Large", WindowSizePreset.large)).tag(WindowSizeChoice.large)
            Divider()
            Text("Custom").tag(WindowSizeChoice.custom)
        }
        .fixedSize()

        if sizeChoice == .custom {
            TextField("Width", value: $customWidth, format: .number.grouping(.never))
                .frame(width: Layout.customFieldWidth)
                .multilineTextAlignment(.trailing)
            Text("\u{00D7}")
                .foregroundStyle(.secondary)
            TextField("Height", value: $customHeight, format: .number.grouping(.never))
                .frame(width: Layout.customFieldWidth)
                .multilineTextAlignment(.trailing)
        }
    }

    private var templateDefaultLabel: String {
        let size = selection.defaultWindowSize
        let dimensions = "\(Int(size.width))\u{00D7}\(Int(size.height))"
        switch selection {
        case .blank: return "Default (\(dimensions))"
        case .template: return "Template Default (\(dimensions))"
        }
    }

    private func presetLabel(_ name: String, _ size: CGSize) -> String {
        "\(name) (\(Int(size.width))\u{00D7}\(Int(size.height)))"
    }

    private var dontShowAgainBinding: Binding<Bool> {
        Binding(
            get: { !showsChooser },
            set: { showsChooser = !$0 }
        )
    }

    // MARK: Size Resolution

    /// The size override handed to instantiation — `nil` when the template's
    /// own default should stand.
    private var windowSizeOverride: CGSize? {
        switch sizeChoice {
        case .templateDefault: nil
        case .compact: WindowSizePreset.compact
        case .standard: WindowSizePreset.standard
        case .large: WindowSizePreset.large
        case .custom: CGSize(
                width: customWidth.clamped(
                    to: WindowSizePreset.minimumWidth ... WindowSizePreset.maximumWidth
                ),
                height: customHeight.clamped(
                    to: WindowSizePreset.minimumHeight ... WindowSizePreset.maximumHeight
                )
            )
        }
    }

    /// The size currently in effect, for seeding the custom fields.
    private var resolvedWindowSize: CGSize {
        windowSizeOverride ?? selection.defaultWindowSize
    }
}

// MARK: - Tile

/// One gallery tile: thumbnail (or the plain Blank card) with a selection
/// ring and the template name beneath.
private struct TemplateTile: View {
    let title: String
    let entry: TemplateEntry?
    let registry: TemplateRegistry
    let isSelected: Bool
    let onSelect: () -> Void
    let onCreate: () -> Void

    @State private var thumbnail: NSImage?

    private enum Layout {
        static let thumbnailWidth: CGFloat = 148
        static let thumbnailHeight: CGFloat = 96
        static let cornerRadius: CGFloat = 6
        static let selectionRingWidth: CGFloat = 3
        static let selectionRingPadding: CGFloat = 3
        static let titleSpacing: CGFloat = 8
    }

    var body: some View {
        VStack(spacing: Layout.titleSpacing) {
            thumbnailCard
                .frame(width: Layout.thumbnailWidth, height: Layout.thumbnailHeight)
                .padding(Layout.selectionRingPadding + Layout.selectionRingWidth)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Layout.cornerRadius + Layout.selectionRingPadding)
                            .strokeBorder(Color.accentColor, lineWidth: Layout.selectionRingWidth)
                    }
                }

            Text(title)
                .font(.callout)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded {
            onCreate()
        })
        .simultaneousGesture(TapGesture().onEnded {
            onSelect()
        })
        .task(id: entry?.url) {
            guard let entry else { return }
            thumbnail = await registry.thumbnail(for: entry)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var thumbnailCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Layout.cornerRadius)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
            }

            RoundedRectangle(cornerRadius: Layout.cornerRadius)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

// MARK: - Clamping

private extension Double {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(CGFloat(self), range.lowerBound), range.upperBound)
    }
}
