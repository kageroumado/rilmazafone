import SwiftUI

struct DMGSettingsSection: View {
    @Environment(RilmazafoneDocument.self) private var document
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Section("DMG Settings") {
            TextField("Volume Name", text: Binding(
                get: { document.volumeName },
                set: { document.setVolumeName($0, undoManager: undoManager) }
            ))
            .textFieldStyle(.roundedBorder)

            Picker("Format", selection: formatBinding) {
                ForEach(DMGImageFormat.allCases, id: \.self) { format in
                    Text(format.displayName).tag(format)
                }
            }

            Picker("Filesystem", selection: filesystemBinding) {
                ForEach(DMGFilesystem.allCases, id: \.self) { fs in
                    Text(fs.displayName).tag(fs)
                }
            }
        }
    }

    private var formatBinding: Binding<DMGImageFormat> {
        Binding(
            get: { document.dmgFormat },
            set: { document.setDMGFormat($0, undoManager: undoManager) }
        )
    }

    private var filesystemBinding: Binding<DMGFilesystem> {
        Binding(
            get: { document.filesystem },
            set: { document.setFilesystem($0, undoManager: undoManager) }
        )
    }
}
