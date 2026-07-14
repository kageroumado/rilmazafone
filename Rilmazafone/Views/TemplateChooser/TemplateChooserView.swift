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
    let state: TemplateChooserState
    let onCreate: (TemplateChooserSelection, CGSize?) -> Void
    let onCancel: () -> Void

    @State private var sizeChoice: WindowSizeChoice = .templateDefault
    @State private var customWidth: Double = Double(WindowSizePreset.standard.width)
    @State private var customHeight: Double = Double(WindowSizePreset.standard.height)
    @AppStorage(NewDocumentPolicy.showsChooserDefaultsKey) private var showsChooser = true

    private enum Layout {
        static let windowWidth: CGFloat = 700
        static let windowHeight: CGFloat = 540
        static let gridSpacing: CGFloat = 16
        static let gridPadding: CGFloat = 24
        /// The grid's vertical inset — tighter than the horizontal one so the
        /// header, rows, and footer read as one column of content.
        static let gridVerticalPadding: CGFloat = 14
        static let tileWidth: CGFloat = 196
        static let customFieldWidth: CGFloat = 52
        /// Clears the traffic lights overlaying the full-size content view.
        static let headerTopPadding: CGFloat = 32
        static let headerBottomPadding: CGFloat = 4
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            gallery
            Divider()
            footer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .frame(width: Layout.windowWidth, height: Layout.windowHeight)
        .onChange(of: state.selection) {
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

    // MARK: Header

    /// Pages-style large title drawn in the content area — the window's own
    /// title bar is transparent with a hidden title.
    private var header: some View {
        Text("Choose a Template")
            .font(.system(size: 22, weight: .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Layout.gridPadding)
            .padding(.top, Layout.headerTopPadding)
            .padding(.bottom, Layout.headerBottomPadding)
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
                    isSelected: state.selection == .blank,
                    onSelect: { state.selection = .blank },
                    onCreate: { createSelection(.blank) }
                )
                ForEach(registry.bundled) { entry in
                    tile(for: entry)
                }
                ForEach(registry.user) { entry in
                    tile(for: entry)
                }
            }
            .padding(.horizontal, Layout.gridPadding)
            .padding(.vertical, Layout.gridVerticalPadding)
        }
    }

    @ViewBuilder
    private func tile(for entry: TemplateEntry) -> some View {
        let tile = TemplateTile(
            title: entry.name,
            entry: entry,
            registry: registry,
            isSelected: state.selection == .template(entry),
            onSelect: { state.selection = .template(entry) },
            onCreate: { createSelection(.template(entry)) }
        )
        if entry.isBuiltIn {
            tile
        } else {
            tile.contextMenu {
                Button("Rename\u{2026}") { rename(entry) }
                Button("Show in Finder") { registry.revealInFinder(entry) }
                Divider()
                Button("Delete\u{2026}", role: .destructive) { delete(entry) }
            }
        }
    }

    private func createSelection(_ newSelection: TemplateChooserSelection) {
        state.selection = newSelection
        onCreate(newSelection, windowSizeOverride)
    }

    // MARK: User Template Actions

    /// Renames a user template via a name prompt, keeping the selection on the
    /// renamed entry.
    private func rename(_ entry: TemplateEntry) {
        guard let name = TemplateSaveCoordinator.promptForTemplateName(
            title: "Rename Template",
            informativeText: "Enter a new name for \u{201C}\(entry.name)\u{201D}.",
            defaultName: entry.name,
            confirmTitle: "Rename"
        ), name != entry.name else { return }

        do {
            let renamed = try registry.renameUserTemplate(entry, to: name)
            if state.selection == .template(entry) {
                state.selection = .template(renamed)
            }
        } catch {
            presentActionError(error, title: "Couldn\u{2019}t Rename \u{201C}\(entry.name)\u{201D}")
        }
    }

    /// Deletes a user template after confirmation; the package moves to the
    /// Trash, never a hard delete.
    private func delete(_ entry: TemplateEntry) {
        let alert = NSAlert()
        alert.messageText = "Delete \u{201C}\(entry.name)\u{201D}?"
        alert.informativeText = "The template will be moved to the Trash."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try registry.deleteUserTemplate(entry)
            if state.selection == .template(entry) {
                state.selection = .blank
            }
        } catch {
            presentActionError(error, title: "Couldn\u{2019}t Delete \u{201C}\(entry.name)\u{201D}")
        }
    }

    private func presentActionError(_ error: any Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Toggle("Don't show this dialog again", isOn: dontShowAgainBinding)
                    .controlSize(.small)

                Spacer()

                sizeControl
            }

            HStack(spacing: 12) {
                Button("Template from DMG\u{2026}") {
                    TemplateSaveCoordinator.shared.createTemplateFromDMG()
                }

                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    onCreate(state.selection, windowSizeOverride)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        let size = state.selection.defaultWindowSize
        let dimensions = "\(Int(size.width))\u{00D7}\(Int(size.height))"
        switch state.selection {
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
        windowSizeOverride ?? state.selection.defaultWindowSize
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
        static let thumbnailWidth: CGFloat = 196
        static let thumbnailHeight: CGFloat = 132
        static let selectionCornerRadius: CGFloat = 10
        static let selectionRingWidth: CGFloat = 3
        static let selectionRingPadding: CGFloat = 5
        static let titleSpacing: CGFloat = 8
    }

    var body: some View {
        VStack(spacing: Layout.titleSpacing) {
            thumbnailCard
                .frame(width: Layout.thumbnailWidth, height: Layout.thumbnailHeight)
                .padding(Layout.selectionRingPadding + Layout.selectionRingWidth)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Layout.selectionCornerRadius)
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
        MiniFinderWindow(
            image: thumbnail,
            windowSize: entry?.windowSize ?? TemplateRegistry.blankWindowSize,
            labelPills: entry?.labelPills ?? []
        )
    }
}

// MARK: - Mini Finder Window

/// Renders a template thumbnail inside miniature Finder window chrome so the
/// gallery shows the design exactly as a mounted DMG presents it — title bar
/// included, keeping the vertical composition honest. Chrome metrics and
/// colors mirror `CanvasView`'s mock window (32 pt title bar, 18 pt corner
/// radius, 14 pt traffic lights), scaled to the tile.
private struct MiniFinderWindow: View {
    /// The baked content-area composite; `nil` renders Finder's default
    /// window fill (the Blank tile, or a thumbnail still loading).
    let image: NSImage?
    /// The template's content-area size in document points.
    let windowSize: CGSize
    /// Redacted stand-ins for item labels, in content-space points.
    let labelPills: [TemplateEntry.LabelPill]

    @Environment(\.colorScheme) private var colorScheme

    private enum Chrome {
        static let titleBarHeight: CGFloat = 32
        static let cornerRadius: CGFloat = 18
        static let lightDiameter: CGFloat = 14
        static let lightSpacing: CGFloat = 8
        static let leadingPadding: CGFloat = 9
        static let lightTitleBar = Color(white: 0.96)
        static let darkTitleBar = Color(white: 0.17)
        static let lightWindowContent = Color.white
        static let darkWindowContent = Color(white: 0.12)
        static let trafficLights: [Color] = [
            Color(red: 1, green: 0.38, blue: 0.34),
            Color(red: 1, green: 0.74, blue: 0.21),
            Color(red: 0.15, green: 0.78, blue: 0.26),
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = min(
                geometry.size.width / windowSize.width,
                geometry.size.height / (windowSize.height + Chrome.titleBarHeight)
            )

            VStack(spacing: 0) {
                titleBar(scale: scale)
                content(scale: scale)
            }
            .clipShape(RoundedRectangle(cornerRadius: Chrome.cornerRadius * scale))
            .overlay {
                RoundedRectangle(cornerRadius: Chrome.cornerRadius * scale)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func titleBar(scale: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(colorScheme == .dark ? Chrome.darkTitleBar : Chrome.lightTitleBar)

            HStack(spacing: Chrome.lightSpacing * scale) {
                ForEach(Array(Chrome.trafficLights.enumerated()), id: \.offset) { _, color in
                    Circle()
                        .fill(color)
                        .frame(
                            width: Chrome.lightDiameter * scale,
                            height: Chrome.lightDiameter * scale
                        )
                }
            }
            .padding(.leading, Chrome.leadingPadding * scale)
        }
        .frame(
            width: windowSize.width * scale,
            height: Chrome.titleBarHeight * scale
        )
    }

    @ViewBuilder
    private func content(scale: CGFloat) -> some View {
        let size = CGSize(
            width: windowSize.width * scale,
            height: windowSize.height * scale
        )
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
            } else {
                Rectangle()
                    .fill(colorScheme == .dark ? Chrome.darkWindowContent : Chrome.lightWindowContent)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            ForEach(Array(labelPills.enumerated()), id: \.offset) { _, pill in
                Capsule()
                    .fill(.ultraThinMaterial)
                    .frame(width: pill.width * scale, height: pill.height * scale)
                    .offset(
                        x: (pill.x - pill.width / 2) * scale,
                        y: (pill.y - pill.height / 2) * scale
                    )
            }
        }
    }
}

// MARK: - Clamping

private extension Double {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(CGFloat(self), range.lowerBound), range.upperBound)
    }
}
