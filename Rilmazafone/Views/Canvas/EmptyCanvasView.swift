import SwiftUI

struct EmptyCanvasView: View {
    @Binding var isFileImporterPresented: Bool

    var body: some View {
        ContentUnavailableView {
            Label("Drop an Application Here", systemImage: "plus.app")
        } actions: {
            Button("Choose Application\u{2026}") {
                isFileImporterPresented = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
