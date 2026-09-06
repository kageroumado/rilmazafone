#if !APPSTORE
    import AppKit
    import Foundation

    // MARK: - Update Check

    /// Points the GitHub build at a newer release when one exists. This is
    /// tooling, not a shipping app, so it never updates in place — it finds the
    /// latest published tag and offers to open the releases page. The App Store
    /// build compiles this out; the store handles its own updates.
    nonisolated enum UpdateCheck {
        static let repo = "kageroumado/rilmazafone"
        static let releasesPageURL = URL(string: "https://github.com/\(repo)/releases/latest")!

        struct Result: Sendable {
            var current: String
            var latest: String
            var updateAvailable: Bool
            var pageURL: URL
        }

        /// The running build's marketing version, from its own bundle.
        static var currentVersion: String {
            (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        }

        /// Queries GitHub for the latest release tag. Returns `nil` on any
        /// network or parse failure — a version check never blocks the tool.
        static func fetchLatest() async -> Result? {
            let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
            var request = URLRequest(url: api, timeoutInterval: 8)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Rilmazafone", forHTTPHeaderField: "User-Agent")

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = object["tag_name"] as? String
            else { return nil }

            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let current = currentVersion
            let page = (object["html_url"] as? String).flatMap(URL.init(string:)) ?? releasesPageURL
            return Result(
                current: current,
                latest: latest,
                updateAvailable: isNewer(latest, than: current),
                pageURL: page,
            )
        }

        /// Compares dot-separated integer components (`2.6` > `2.5`, `2.6` >
        /// `2.6` is false). Non-numeric components read as 0.
        static func isNewer(_ latest: String, than current: String) -> Bool {
            let latestParts = latest.split(separator: ".").map { Int($0) ?? 0 }
            let currentParts = current.split(separator: ".").map { Int($0) ?? 0 }
            for index in 0 ..< max(latestParts.count, currentParts.count) {
                let l = index < latestParts.count ? latestParts[index] : 0
                let c = index < currentParts.count ? currentParts[index] : 0
                if l != c { return l > c }
            }
            return false
        }
    }

    // MARK: - Presenter

    /// Drives the "Check for Updates…" menu item: fetch, then an alert that
    /// either reassures or offers to open the releases page.
    @MainActor
    enum UpdateCheckPresenter {
        static func present() {
            Task {
                guard let result = await UpdateCheck.fetchLatest() else {
                    showAlert(
                        title: "Couldn\u{2019}t Check for Updates",
                        message: "Rilmazafone couldn\u{2019}t reach GitHub. Check your connection and try again.",
                        pageURL: nil,
                    )
                    return
                }
                if result.updateAvailable {
                    showAlert(
                        title: "Rilmazafone \(result.latest) is available",
                        message: "You have \(result.current). Open the releases page to download the latest build.",
                        pageURL: result.pageURL,
                    )
                } else {
                    showAlert(
                        title: "You\u{2019}re up to date",
                        message: "Rilmazafone \(result.current) is the latest release.",
                        pageURL: nil,
                    )
                }
            }
        }

        private static func showAlert(title: String, message: String, pageURL: URL?) {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            if let pageURL {
                alert.addButton(withTitle: "View Release")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(pageURL)
                }
            } else {
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
#endif
