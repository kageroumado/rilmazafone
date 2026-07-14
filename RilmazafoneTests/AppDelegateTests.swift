import AppKit
import Testing
@testable import Rilmazafone

@MainActor
@Suite("AppDelegate Dock menu")
struct AppDelegateTests {
    @Test("First item is New Document targeting the shared document controller")
    func newDocumentItem() throws {
        let menu = try dockMenu()
        let first = try #require(menu.items.first)

        #expect(first.title == "New Document")
        #expect(first.action == #selector(NSDocumentController.newDocument(_:)))
        #expect(first.target === NSDocumentController.shared)
    }

    @Test("Seeded recent document appears with display name and represented URL")
    func recentDocumentListed() throws {
        let url = try seededRecentDocument()

        let delegate = AppDelegate()
        let menu = try #require(delegate.applicationDockMenu(NSApp))
        let recentItem = try #require(
            menu.items.first { ($0.representedObject as? URL)?.standardizedFileURL == url.standardizedFileURL }
        )

        #expect(recentItem.title == FileManager.default.displayName(atPath: url.path))
        #expect(recentItem.action == #selector(AppDelegate.openRecentDocument(_:)))
        #expect(recentItem.target === delegate)
        #expect(recentItem.image != nil)

        let separatorIndex = try #require(menu.items.firstIndex { $0.isSeparatorItem })
        #expect(separatorIndex > 0)
        #expect(menu.index(of: recentItem) > separatorIndex)
    }

    @Test("Recent documents are capped at ten")
    func recentDocumentsCapped() throws {
        _ = try seededRecentDocument()

        let menu = try dockMenu()
        let recentCount = menu.items.count { $0.representedObject is URL }

        #expect(recentCount >= 1)
        #expect(recentCount <= 10)
    }

    // MARK: - Helpers

    private func dockMenu() throws -> NSMenu {
        try #require(AppDelegate().applicationDockMenu(NSApp))
    }

    /// Creates a real `.dmgtemplate` on disk and registers it with the shared
    /// document controller's recents list.
    private func seededRecentDocument() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "DockMenuTest-\(UUID().uuidString).dmgtemplate")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return url
    }
}
