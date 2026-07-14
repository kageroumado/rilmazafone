import SwiftUI
import UniformTypeIdentifiers

struct BuildSettingsSection: View {
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager

    @State private var isVolumeIconPickerPresented = false
    @State private var signingIdentities: [String] = []
    @State private var hasCheckedIdentities = false
    @State private var composedIconPreview: NSImage?
    @State private var cachedAppIcon: NSImage?

    // Static caches survive view teardown from tab switching
    private static var identitiesCache: [String]?
    private static var composedPreviewCache: (path: String, modified: Date, image: NSImage)?

    var body: some View {
        // MARK: Code Signing

        Section("Code Signing") {
            if signingIdentities.isEmpty, hasCheckedIdentities {
                Label {
                    Text("No signing identities found. Install certificates via Xcode or Keychain Access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } else {
                Toggle(
                    "Code Sign",
                    isOn: Binding(
                        get: { document.configuration.codeSign.enabled },
                        set: { document.setCodeSignEnabled($0, undoManager: undoManager) }
                    )
                )
                .toggleStyle(.switch)
                .disabled(signingIdentities.isEmpty && hasCheckedIdentities)

                if document.configuration.codeSign.enabled {
                    Picker("Identity", selection: identityBinding) {
                        Text("Auto-detect")
                            .tag(String?.none)
                        ForEach(signingIdentities, id: \.self) { identity in
                            Text(abbreviatedIdentity(identity))
                                .tag(String?.some(identity))
                        }
                    }
                    .help("The code signing identity used to sign the DMG")

                    if document.configuration.codeSign.identity == nil,
                       let first = signingIdentities.first {
                        Text("Will use: \(abbreviatedIdentity(first))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            guard !hasCheckedIdentities else { return }
            if let cached = Self.identitiesCache {
                signingIdentities = cached
            } else {
                let result = await Task.detached { DMGBuilder.listSigningIdentities() }.value
                Self.identitiesCache = result
                signingIdentities = result
            }
            hasCheckedIdentities = true
        }

        // MARK: Volume Icon

        Section("Volume Icon") {
            Picker("Type", selection: Binding(
                get: { document.configuration.volumeIcon.type },
                set: { document.setVolumeIconType($0, undoManager: undoManager) }
            )) {
                Text("Auto-compose").tag(VolumeIconType.composed)
                Text("Custom").tag(VolumeIconType.custom)
                Text("None").tag(VolumeIconType.none)
            }

            if document.configuration.volumeIcon.type == .custom {
                if let iconImage = document.volumeIconImage {
                    Image(nsImage: iconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                }

                Button("Choose Icon\u{2026}") {
                    isVolumeIconPickerPresented = true
                }

                Text("Supports PNG, JPEG, TIFF, or ICNS files.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if document.configuration.volumeIcon.type == .composed {
                if let app = document.configuration.items.first(where: { $0.kind == .app }),
                   let path = app.sourcePath {
                    HStack(spacing: 8) {
                        if let preview = composedIconPreview {
                            Image(nsImage: preview)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 48, height: 48)
                        } else if let icon = cachedAppIcon {
                            Image(nsImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 48, height: 48)
                        }

                        Text("Composed from app icon")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .task(id: path) {
                        cachedAppIcon = NSWorkspace.shared.icon(forFile: path)
                        let modDate = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
                        if let cached = Self.composedPreviewCache, cached.path == path, cached.modified == modDate {
                            composedIconPreview = cached.image
                        } else if let preview = await generateComposedPreview(appPath: path) {
                            Self.composedPreviewCache = (path, modDate, preview)
                            composedIconPreview = preview
                        }
                    }
                } else {
                    Text("Add an application to preview the composed icon.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .fileImporter(
            isPresented: $isVolumeIconPickerPresented,
            allowedContentTypes: [.png, .jpeg, .tiff, .icns],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                do {
                    try document.importVolumeIcon(from: url, undoManager: undoManager)
                } catch {
                    NSAlert.showError("Failed to import volume icon", detail: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Identity Helpers

    private var identityBinding: Binding<String?> {
        Binding(
            get: { document.configuration.codeSign.identity },
            set: {
                document.setCodeSignIdentity(
                    $0,
                    undoManager: undoManager
                )
            }
        )
    }

    /// Shorten long identity strings for display
    private func abbreviatedIdentity(_ identity: String) -> String {
        // "Developer ID Application: Very Long Name (TEAMID)" → "Developer ID...: ...Name (TEAMID)"
        if identity.count > 40 {
            return String(identity.prefix(35)) + "\u{2026}"
        }
        return identity
    }

    private func generateComposedPreview(appPath: String) async -> NSImage? {
        guard let iconURL = IconComposer.resolveAppIconURL(appPath: appPath),
              let icnsData = try? await IconComposer.compose(appIconURL: iconURL)
        else { return nil }
        return NSImage(data: icnsData)
    }
}

