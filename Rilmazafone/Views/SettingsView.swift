import SwiftUI

/// App settings. Currently a single pane: whether ⌘N shows the template
/// chooser or creates a blank document (round-trips with the chooser's
/// "Don't show this dialog again" checkbox via the same UserDefaults key).
struct SettingsView: View {
    @AppStorage(NewDocumentPolicy.showsChooserDefaultsKey) private var showsChooser = true

    private enum Layout {
        static let padding: CGFloat = 20
        static let minimumWidth: CGFloat = 360
    }

    var body: some View {
        Form {
            Picker("For New Documents:", selection: $showsChooser) {
                Text("Show Template Chooser").tag(true)
                Text("Create Blank Document").tag(false)
            }
            .pickerStyle(.radioGroup)
        }
        .padding(Layout.padding)
        .frame(minWidth: Layout.minimumWidth)
    }
}
