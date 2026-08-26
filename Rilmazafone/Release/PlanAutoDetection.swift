#if !APPSTORE
    import Foundation

    // MARK: - External Tools

    /// Resolves external executables robustly from a GUI app, whose PATH is the
    /// bare launchd default and misses Homebrew.
    nonisolated enum ExternalTool {
        static let git = "/usr/bin/git"
        static let xcodebuild = "/usr/bin/xcodebuild"
        static let xcrun = "/usr/bin/xcrun"
        static let codesign = "/usr/bin/codesign"
        static let spctl = "/usr/sbin/spctl"
        static let hdiutil = "/usr/bin/hdiutil"
        static let ditto = "/usr/bin/ditto"

        /// `gh` and Homebrew-installed `openssl` live outside the default PATH.
        static func find(_ name: String) -> String? {
            let candidates = [
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)",
                "/usr/bin/\(name)",
            ]
            if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                return hit
            }
            for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
                let path = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
            return nil
        }
    }

    // MARK: - Auto-Detection

    /// Fills plan fields from the project itself: repo from the git remote,
    /// schemes from `xcodebuild -list`, version from the pbxproj, identity from
    /// the keychain. Each result carries where it came from so the form can
    /// show provenance.
    nonisolated enum PlanAutoDetection {
        // MARK: Git

        /// `owner/repo` parsed from the repo's `origin` remote, or `nil` when
        /// there is no remote or it isn't github.com.
        static func githubRepo(repoRoot: URL) async -> String? {
            guard let raw = try? await ProcessRunner.runString(
                ExternalTool.git,
                arguments: ["-C", repoRoot.path, "remote", "get-url", "origin"],
            ) else { return nil }
            return parseGitHubRemote(raw)
        }

        /// Accepts `git@github.com:owner/repo.git`, `https://github.com/owner/repo`,
        /// and `ssh://git@github.com/owner/repo.git`.
        static func parseGitHubRemote(_ remote: String) -> String? {
            let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let range = trimmed.range(of: "github.com") else { return nil }
            var rest = String(trimmed[range.upperBound...])
            if rest.hasPrefix(":") || rest.hasPrefix("/") { rest.removeFirst() }
            if rest.hasSuffix(".git") { rest.removeLast(4) }
            let parts = rest.split(separator: "/")
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return "\(parts[0])/\(parts[1])"
        }

        nonisolated struct GitHubCLIStatus: Sendable, Equatable {
            var installed = false
            var authenticated = false
        }

        /// Whether the `gh` CLI exists and is signed in — the two
        /// prerequisites the GitHub channel silently assumed before.
        static func githubCLIStatus() async -> GitHubCLIStatus {
            guard let gh = ExternalTool.find("gh") else { return GitHubCLIStatus() }
            let authenticated = (try? await ProcessRunner.run(gh, arguments: ["auth", "status"])) != nil
            return GitHubCLIStatus(installed: true, authenticated: authenticated)
        }

        /// Whether `gh` can see the repo and the user has push access.
        static func verifyGitHubRepo(_ repo: String) async -> Bool {
            guard let gh = ExternalTool.find("gh") else { return false }
            guard let out = try? await ProcessRunner.runString(
                gh,
                arguments: [
                    "repo", "view", repo,
                    "--json", "viewerPermission", "--jq", ".viewerPermission",
                ],
            ) else { return false }
            return ["ADMIN", "MAINTAIN", "WRITE"].contains(out)
        }

        // MARK: Schemes

        static func schemes(xcodeprojURL: URL) async -> [String] {
            struct Listing: Decodable {
                struct Project: Decodable { let schemes: [String]? }
                let project: Project
            }
            guard let result = try? await ProcessRunner.run(
                ExternalTool.xcodebuild,
                arguments: ["-list", "-json", "-project", xcodeprojURL.path],
            ) else { return [] }
            let listing = try? JSONDecoder().decode(Listing.self, from: result.stdout)
            return listing?.project.schemes ?? []
        }

        // MARK: Versions

        nonisolated struct ProjectVersion: Sendable, Equatable {
            var marketing: String
            var build: Int
        }

        /// The app's `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` from the
        /// pbxproj. Multi-target projects (app + extensions) can carry several
        /// values; the highest wins — the version bump rewrites every
        /// occurrence, so targets move in lockstep from the first release on
        /// (the same model as `agvtool`) and the app's is never behind.
        static func projectVersion(pbxprojURL: URL) -> ProjectVersion? {
            guard let text = try? String(contentsOf: pbxprojURL, encoding: .utf8) else { return nil }
            let marketing = settingValues("MARKETING_VERSION", in: text)
                .max { versionSortKey($0).lexicographicallyPrecedes(versionSortKey($1)) }
            guard let marketing else { return nil }
            let build = settingValues("CURRENT_PROJECT_VERSION", in: text)
                .compactMap { Int($0) }.max() ?? 0
            return ProjectVersion(marketing: marketing, build: build)
        }

        static func settingValues(_ key: String, in pbxproj: String) -> [String] {
            pbxproj.matches(of: try! Regex("\(key) = ([^;]+);")).compactMap { match in
                match.output[1].substring.map {
                    String($0).trimmingCharacters(in: .whitespacesAndNewlines)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            }
        }

        private static func versionSortKey(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0) ?? 0 }
        }

        /// Rewrites every occurrence of a build setting. Returns the updated
        /// text, or `nil` when the key never appears.
        static func replacingSetting(_ key: String, with value: String, in pbxproj: String) -> String? {
            guard pbxproj.contains("\(key) = ") else { return nil }
            return pbxproj.replacing(try! Regex("\(key) = [^;]+;")) { _ in "\(key) = \(value);" }
        }

        static func bumped(_ version: String, policy: ReleasePlan.BumpPolicy) -> String {
            var parts = version.split(separator: ".").map { Int($0) ?? 0 }
            while parts.count < 2 { parts.append(0) }
            switch policy {
            case .minor:
                return "\(parts[0]).\(parts[1] + 1)"
            case .patch:
                while parts.count < 3 { parts.append(0) }
                return "\(parts[0]).\(parts[1]).\(parts[2] + 1)"
            }
        }

        // MARK: Identity

        /// Preferred signing identity for release distribution: the keychain's
        /// Developer ID Application certificate, if any.
        static func developerIDIdentity() -> String? {
            DMGBuilder.listSigningIdentities().first { $0.hasPrefix("Developer ID Application") }
        }

        /// Cheap probe that the notary keychain profile exists: `notarytool
        /// history` fails fast with a keychain error when it doesn't.
        static func verifyNotaryProfile(_ profile: String) async -> Bool {
            guard !profile.isEmpty else { return false }
            let result = try? await ProcessRunner.run(
                ExternalTool.xcrun,
                arguments: ["notarytool", "history", "--keychain-profile", profile, "--output-format", "json"],
            )
            return result != nil
        }
    }
#endif
