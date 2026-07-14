import AppKit
import Foundation
import Testing
@testable import Rilmazafone

// MARK: - Fixtures

/// Builds disposable `.dmgtemplate` fixtures in a private temporary directory,
/// so the tests never depend on bundled templates existing in the app.
private enum TemplateFixtures {
    static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TemplateRegistryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    static func writeTemplate(
        named name: String,
        in directory: URL,
        windowSize: CGSize = CGSize(width: 660, height: 400),
        includesPlaceholder: Bool = true,
        items: [CanvasItem]? = nil,
        background: BackgroundConfiguration? = nil,
        assets: [String: Data] = [:]
    ) throws -> URL {
        var configuration = DMGConfiguration()
        configuration.volumeName = name
        configuration.window.width = windowSize.width
        configuration.window.height = windowSize.height
        if let items {
            configuration.items = items
        } else if includesPlaceholder {
            configuration.items = [
                .appPlaceholder(position: CGPoint(x: 180, y: 190)),
                CanvasItem(
                    kind: .applicationsSymlink,
                    label: "Applications",
                    position: CGPoint(x: 480, y: 190)
                ),
            ]
        }
        if let background {
            configuration.background = background
        }

        let url = directory.appending(path: "\(name).dmgtemplate")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try JSONEncoder().encode(configuration).write(to: url.appending(path: "document.json"))

        if !assets.isEmpty {
            let assetsDirectory = url.appending(path: "Assets")
            try FileManager.default.createDirectory(
                at: assetsDirectory, withIntermediateDirectories: true
            )
            for (filename, data) in assets {
                try data.write(to: assetsDirectory.appending(path: filename))
            }
        }
        return url
    }
}

@MainActor
private func makeRegistry(bundled: URL?, user: URL) -> TemplateRegistry {
    TemplateRegistry(
        bundledDirectory: bundled,
        userDirectory: user,
        watchesUserDirectory: false,
        prewarmsThumbnails: false
    )
}

// MARK: - Registry

@MainActor
@Suite("Template Registry")
struct TemplateRegistryTests {
    @Test("Scans bundled and user directories into name-sorted entries")
    func scansAndSorts() throws {
        let bundledDir = try TemplateFixtures.makeDirectory()
        let userDir = try TemplateFixtures.makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: bundledDir)
            try? FileManager.default.removeItem(at: userDir)
        }

        try TemplateFixtures.writeTemplate(named: "Zeta", in: bundledDir)
        try TemplateFixtures.writeTemplate(named: "Alpha", in: bundledDir)
        try TemplateFixtures.writeTemplate(named: "Mine", in: userDir)

        let registry = makeRegistry(bundled: bundledDir, user: userDir)

        #expect(registry.bundled.map(\.name) == ["Alpha", "Zeta"])
        #expect(registry.bundled.allSatisfy { $0.isBuiltIn })
        #expect(registry.user.map(\.name) == ["Mine"])
        #expect(registry.user.allSatisfy { !$0.isBuiltIn })
    }

    @Test("An absent bundled directory yields an empty bundled list")
    func absentBundledDirectory() throws {
        let userDir = try TemplateFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }

        let missing = FileManager.default.temporaryDirectory
            .appending(path: "does-not-exist-\(UUID().uuidString)")
        let registry = makeRegistry(bundled: missing, user: userDir)

        #expect(registry.bundled.isEmpty)
        #expect(registry.user.isEmpty)
    }

    @Test("Entries parse the template's window size from its configuration")
    func parsesWindowSize() throws {
        let userDir = try TemplateFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }

        try TemplateFixtures.writeTemplate(
            named: "Wide", in: userDir, windowSize: CGSize(width: 800, height: 500)
        )
        let registry = makeRegistry(bundled: nil, user: userDir)

        let entry = try #require(registry.user.first)
        #expect(entry.windowSize == CGSize(width: 800, height: 500))
    }

    @Test("refresh() picks up added and removed templates")
    func refreshTracksChanges() throws {
        let userDir = try TemplateFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }

        let registry = makeRegistry(bundled: nil, user: userDir)
        #expect(registry.user.isEmpty)

        let added = try TemplateFixtures.writeTemplate(named: "Fresh", in: userDir)
        registry.refresh()
        #expect(registry.user.map(\.name) == ["Fresh"])

        try FileManager.default.removeItem(at: added)
        registry.refresh()
        #expect(registry.user.isEmpty)
    }

    @Test("Non-template entries and packages without a manifest are ignored")
    func ignoresStrays() throws {
        let userDir = try TemplateFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }

        try Data("stray".utf8).write(to: userDir.appending(path: "notes.txt"))
        try FileManager.default.createDirectory(
            at: userDir.appending(path: "Broken.dmgtemplate"),
            withIntermediateDirectories: true
        )
        try TemplateFixtures.writeTemplate(named: "Valid", in: userDir)

        let registry = makeRegistry(bundled: nil, user: userDir)
        #expect(registry.user.map(\.name) == ["Valid"])
    }

    @Test("The directory watcher refreshes the user list without an explicit refresh")
    func watcherRefreshes() async throws {
        let userDir = try TemplateFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }

        let registry = TemplateRegistry(
            bundledDirectory: nil,
            userDirectory: userDir,
            watchesUserDirectory: true,
            prewarmsThumbnails: false
        )
        #expect(registry.user.isEmpty)

        try TemplateFixtures.writeTemplate(named: "Watched", in: userDir)

        var sawTemplate = false
        for _ in 0 ..< 100 {
            if registry.user.map(\.name) == ["Watched"] {
                sawTemplate = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawTemplate)
    }

    // MARK: User Template Management

    @Test("saveUserTemplate writes a readable package and lists it")
    func saveUserTemplate() throws {
        let userDir = try TemplateFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }

        let registry = makeRegistry(bundled: nil, user: userDir)
        var configuration = DMGConfiguration()
        configuration.window.width = 720
        configuration.window.height = 440
        configuration.items = [.appPlaceholder(position: CGPoint(x: 100, y: 100))]
        let payload = Data([0x89, 0x50, 0x4E, 0x47])

        let entry = try registry.saveUserTemplate(
            named: "My Design",
            configuration: configuration,
            assets: ["background.png": payload]
        )

        #expect(registry.user.contains(entry))
        #expect(entry.windowSize == CGSize(width: 720, height: 440))

        let reloaded = try TemplateInstantiator.configuration(ofTemplateAt: entry.url)
        #expect(reloaded.items.count == 1)
        #expect(reloaded.items[0].isPlaceholder)
        #expect(TemplateInstantiator.assets(ofTemplateAt: entry.url) == ["background.png": payload])
    }

    @Test("saveUserTemplate uniques a taken name")
    func saveUniquesName() throws {
        let userDir = try TemplateFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }

        let registry = makeRegistry(bundled: nil, user: userDir)
        let first = try registry.saveUserTemplate(named: "Dup", configuration: DMGConfiguration())
        let second = try registry.saveUserTemplate(named: "Dup", configuration: DMGConfiguration())

        #expect(first.url != second.url)
        #expect(registry.user.count == 2)
    }

    @Test("renameUserTemplate moves the package and updates the list")
    func renameUserTemplate() throws {
        let userDir = try TemplateFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }

        let registry = makeRegistry(bundled: nil, user: userDir)
        let original = try registry.saveUserTemplate(named: "Before", configuration: DMGConfiguration())

        let renamed = try registry.renameUserTemplate(original, to: "After")

        #expect(renamed.name == "After")
        #expect(registry.user.map(\.name) == ["After"])
        #expect(!FileManager.default.fileExists(atPath: original.url.path))
    }

    @Test("deleteUserTemplate moves the package to the Trash")
    func deleteUserTemplate() throws {
        let userDir = try TemplateFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }

        let registry = makeRegistry(bundled: nil, user: userDir)
        let entry = try registry.saveUserTemplate(named: "Doomed", configuration: DMGConfiguration())

        try registry.deleteUserTemplate(entry)

        #expect(registry.user.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: entry.url.path))
    }

    // MARK: Thumbnails

    @Test("Thumbnails render at the template's window size and are cached")
    func thumbnailRendersAndCaches() async throws {
        let userDir = try TemplateFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: userDir) }

        var background = BackgroundConfiguration()
        background.type = .gradient
        background.gradient = GradientConfiguration()
        try TemplateFixtures.writeTemplate(
            named: "Pretty",
            in: userDir,
            windowSize: CGSize(width: 500, height: 340),
            background: background
        )

        let registry = makeRegistry(bundled: nil, user: userDir)
        let entry = try #require(registry.user.first)

        let first = try #require(await registry.thumbnail(for: entry))
        #expect(first.size == CGSize(width: 500, height: 340))

        let second = try #require(await registry.thumbnail(for: entry))
        #expect(first === second)
    }
}

// MARK: - Instantiation

@Suite("Template Instantiation")
struct TemplateInstantiatorTests {
    @Test("Instantiation keeps the template's window size when no override is chosen")
    func keepsTemplateDefaultSize() throws {
        let directory = try TemplateFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try TemplateFixtures.writeTemplate(
            named: "Sized", in: directory, windowSize: CGSize(width: 800, height: 500)
        )
        let result = try TemplateInstantiator.instantiate(templateAt: url, windowSizeOverride: nil)

        #expect(result.configuration.window.width == 800)
        #expect(result.configuration.window.height == 500)
    }

    @Test("A window-size override replaces the template's size and keeps the placeholder")
    func overrideAppliesAndPlaceholderSurvives() throws {
        let directory = try TemplateFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try TemplateFixtures.writeTemplate(
            named: "Overridden", in: directory, windowSize: CGSize(width: 800, height: 500)
        )
        let result = try TemplateInstantiator.instantiate(
            templateAt: url,
            windowSizeOverride: CGSize(width: 500, height: 340)
        )

        #expect(result.configuration.window.width == 500)
        #expect(result.configuration.window.height == 340)

        let placeholder = try #require(result.configuration.items.first { $0.isPlaceholder })
        #expect(placeholder.kind == .app)
        #expect(placeholder.label == CanvasItem.placeholderLabel)
        #expect(placeholder.position == CGPoint(x: 180, y: 190))
        #expect(result.configuration.items.contains { $0.kind == .applicationsSymlink })
    }

    @Test("Instantiation loads asset payloads keyed by filename")
    func loadsAssets() throws {
        let directory = try TemplateFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data("image-bytes".utf8)
        let url = try TemplateFixtures.writeTemplate(
            named: "WithAssets", in: directory, assets: ["background.png": payload]
        )
        let result = try TemplateInstantiator.instantiate(templateAt: url, windowSizeOverride: nil)

        #expect(result.assets == ["background.png": payload])
    }

    @Test("Abbreviated home paths are expanded on load")
    func expandsAbbreviatedPaths() throws {
        let directory = try TemplateFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let item = CanvasItem(
            kind: .app,
            label: "Tool.app",
            sourcePath: "~/Applications/Tool.app",
            position: .zero
        )
        let url = try TemplateFixtures.writeTemplate(named: "Homey", in: directory, items: [item])

        let configuration = try TemplateInstantiator.configuration(ofTemplateAt: url)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(configuration.items[0].sourcePath == home + "/Applications/Tool.app")
    }

    @Test("A package without document.json throws unreadableTemplate")
    func unreadableTemplateThrows() throws {
        let directory = try TemplateFixtures.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appending(path: "Empty.dmgtemplate")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        #expect {
            try TemplateInstantiator.configuration(ofTemplateAt: url)
        } throws: { error in
            guard case TemplateInstantiator.TemplateError.unreadableTemplate = error else {
                return false
            }
            return true
        }
    }

    @Test("A blank result carries the chosen window size and no items")
    func blankResult() {
        let result = TemplateInstantiator.blank(windowSize: CGSize(width: 800, height: 500))
        #expect(result.configuration.window.width == 800)
        #expect(result.configuration.window.height == 500)
        #expect(result.configuration.items.isEmpty)
        #expect(result.assets.isEmpty)
    }
}

// MARK: - New Document Policy

@Suite("New Document Policy")
struct NewDocumentPolicyTests {
    @Test(
        "The decision function honors the preference and the explicit request",
        arguments: [
            (showsChooser: true, explicit: false, expected: NewDocumentPolicy.Action.showChooser),
            (showsChooser: false, explicit: false, expected: .createBlankDocument),
            (showsChooser: false, explicit: true, expected: .showChooser),
            (showsChooser: true, explicit: true, expected: .showChooser),
        ]
    )
    func decision(
        _ combination: (showsChooser: Bool, explicit: Bool, expected: NewDocumentPolicy.Action)
    ) {
        #expect(
            NewDocumentPolicy.action(
                showsChooser: combination.showsChooser,
                isExplicitChooserRequest: combination.explicit
            ) == combination.expected
        )
    }

    @Test("The preference defaults to showing the chooser and round-trips")
    func preferenceRoundTrip() throws {
        let suiteName = "NewDocumentPolicyTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(NewDocumentPolicy.showsChooser(in: defaults) == true)

        defaults.set(false, forKey: NewDocumentPolicy.showsChooserDefaultsKey)
        #expect(NewDocumentPolicy.showsChooser(in: defaults) == false)

        defaults.set(true, forKey: NewDocumentPolicy.showsChooserDefaultsKey)
        #expect(NewDocumentPolicy.showsChooser(in: defaults) == true)
    }
}

// MARK: - Dock Menu

@MainActor
@Suite("Dock template submenu")
struct DockTemplateMenuTests {
    @Test("Dock menu grows a New from Template submenu when the registry has entries")
    func dockSubmenuListsRegistryEntries() throws {
        // The Dock menu reads the shared registry, whose contents depend on
        // the environment; assert the structure matches it either way.
        let delegate = AppDelegate()
        let menu = try #require(delegate.applicationDockMenu(NSApp))
        let registry = TemplateRegistry.shared

        let submenuItem = menu.items.first { $0.title == "New from Template" }
        if registry.bundled.isEmpty, registry.user.isEmpty {
            #expect(submenuItem == nil)
        } else {
            let submenu = try #require(submenuItem?.submenu)
            let titles = submenu.items.filter { !$0.isSeparatorItem }.map(\.title)
            #expect(titles == (registry.bundled + registry.user).map(\.name))
            for item in submenu.items where !item.isSeparatorItem {
                #expect(item.target === delegate)
                #expect(item.action == #selector(AppDelegate.newDocumentFromTemplate(_:)))
                #expect(item.representedObject is TemplateEntry)
            }
        }
    }
}
