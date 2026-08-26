#if !APPSTORE
    import Foundation

    // MARK: - Release Plan

    /// The persisted model of a `.releaseplan` document: everything the release
    /// pipeline needs to take an Xcode project to distributable artifacts (and,
    /// optionally, a published GitHub release).
    ///
    /// The plan holds keychain *references* (signing identity name, notary
    /// profile name) and paths — never secrets — so the file is committable.
    /// Relative paths resolve against the repository root, which itself
    /// defaults to the folder containing the `.releaseplan` bundle.
    nonisolated struct ReleasePlan: Codable, Hashable {
        var version: Int = 1

        /// Stable identity linking this plan to its build records across
        /// renames and moves.
        var identity: UUID = .init()

        var project: Project = .init()
        var signing: Signing = .init()
        var notarization: Notarization = .init()
        var design: Design = .init()
        var artifacts: Artifacts = .init()
        var versioning: Versioning = .init()
        var publish: Publish = .init()

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            self.identity = try container.decodeIfPresent(UUID.self, forKey: .identity) ?? UUID()
            self.project = try container.decodeIfPresent(Project.self, forKey: .project) ?? .init()
            self.signing = try container.decodeIfPresent(Signing.self, forKey: .signing) ?? .init()
            self.notarization = try container.decodeIfPresent(Notarization.self, forKey: .notarization) ?? .init()
            self.design = try container.decodeIfPresent(Design.self, forKey: .design) ?? .init()
            self.artifacts = try container.decodeIfPresent(Artifacts.self, forKey: .artifacts) ?? .init()
            self.versioning = try container.decodeIfPresent(Versioning.self, forKey: .versioning) ?? .init()
            self.publish = try container.decodeIfPresent(Publish.self, forKey: .publish) ?? .init()
        }

        // MARK: - Project

        nonisolated struct Project: Codable, Hashable {
            /// Repository root. Relative paths resolve against the plan's
            /// containing folder; `nil` means the plan lives in the repo root.
            var path: String?

            /// The `.xcodeproj` name inside the repo root; `nil` auto-discovers
            /// the first one found.
            var xcodeproj: String?

            /// Scheme to archive; `nil` defaults to the project's name.
            var scheme: String?

            /// App name (the archived product is `<appName>.app`); `nil`
            /// defaults to the scheme.
            var appName: String?

            var archs: [String] = ["arm64"]

            /// Optional repo-relative Swift file holding a
            /// `marketingVersion = "X"` constant bumped alongside the project.
            var versionConstant: String?

            /// Extra `KEY=VALUE` settings passed to `xcodebuild archive`.
            var extraBuildSettings: [String: String] = [:]

            init() {}

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.path = try container.decodeIfPresent(String.self, forKey: .path)
                self.xcodeproj = try container.decodeIfPresent(String.self, forKey: .xcodeproj)
                self.scheme = try container.decodeIfPresent(String.self, forKey: .scheme)
                self.appName = try container.decodeIfPresent(String.self, forKey: .appName)
                self.archs = try container.decodeIfPresent([String].self, forKey: .archs) ?? ["arm64"]
                self.versionConstant = try container.decodeIfPresent(String.self, forKey: .versionConstant)
                self.extraBuildSettings = try container
                    .decodeIfPresent([String: String].self, forKey: .extraBuildSettings) ?? [:]
            }
        }

        // MARK: - Signing

        nonisolated struct Signing: Codable, Hashable {
            /// Keychain identity name; `nil` auto-detects a Developer ID
            /// Application identity.
            var identity: String?

            /// Repo-relative entitlements file for the final main-app re-sign.
            /// Only needed for restricted entitlements (iCloud, APS).
            var entitlements: String?

            /// Provisioning profile embedded as
            /// `Contents/embedded.provisionprofile`; required for AMFI to honor
            /// restricted entitlements on Developer ID builds.
            var provisioningProfile: String?

            init() {}

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.identity = try container.decodeIfPresent(String.self, forKey: .identity)
                self.entitlements = try container.decodeIfPresent(String.self, forKey: .entitlements)
                self.provisioningProfile = try container.decodeIfPresent(String.self, forKey: .provisioningProfile)
            }
        }

        // MARK: - Notarization

        nonisolated struct Notarization: Codable, Hashable {
            /// `notarytool` keychain profile name (created once with
            /// `xcrun notarytool store-credentials`).
            var keychainProfile: String = ""

            init() {}

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.keychainProfile = try container.decodeIfPresent(String.self, forKey: .keychainProfile) ?? ""
            }
        }

        // MARK: - Design

        nonisolated enum DesignSource: String, Codable {
            /// The design lives inside the plan bundle as `Design.dmgtemplate`.
            case embedded
            /// The design is an external `.dmgtemplate` at `path`.
            case path
        }

        nonisolated struct Design: Codable, Hashable {
            var source: DesignSource = .embedded
            /// Repo-relative or absolute path to an external template
            /// (`source == .path` only).
            var path: String?

            init() {}

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.source = try container.decodeIfPresent(DesignSource.self, forKey: .source) ?? .embedded
                self.path = try container.decodeIfPresent(String.self, forKey: .path)
            }
        }

        // MARK: - Artifacts

        nonisolated struct Artifacts: Codable, Hashable {
            /// Also produce a `ditto` zip of the bare signed app (for external
            /// updaters).
            var appZip: Bool = false

            /// Path to an Ed25519 private key; when set, the stapled DMG is
            /// signed and a base64 `.sig` artifact is produced.
            var eddsaPrivateKey: String?

            /// Directory receiving `<App>-<version>-b<build>-dSYMs.zip`;
            /// `nil` skips dSYM preservation.
            var dsymArchiveDir: String?

            /// Where finished artifacts land; `nil` uses
            /// `~/Library/Application Support/Rilmazafone/Releases/<plan>/`.
            var outputDir: String?

            init() {}

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.appZip = try container.decodeIfPresent(Bool.self, forKey: .appZip) ?? false
                self.eddsaPrivateKey = try container.decodeIfPresent(String.self, forKey: .eddsaPrivateKey)
                self.dsymArchiveDir = try container.decodeIfPresent(String.self, forKey: .dsymArchiveDir)
                self.outputDir = try container.decodeIfPresent(String.self, forKey: .outputDir)
            }
        }

        // MARK: - Versioning

        nonisolated enum BumpPolicy: String, Codable, CaseIterable {
            case minor
            case patch

            var label: String {
                switch self {
                case .minor: "Bump minor"
                case .patch: "Bump patch"
                }
            }
        }

        nonisolated struct Versioning: Codable, Hashable {
            var bump: BumpPolicy = .minor

            init() {}

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.bump = try container.decodeIfPresent(BumpPolicy.self, forKey: .bump) ?? .minor
            }
        }

        // MARK: - Publish

        nonisolated enum PublishChannel: String, Codable, CaseIterable {
            case github
            case script
            /// Build-only: artifacts are the deliverable, nothing leaves the
            /// machine and the version bump stays uncommitted.
            case none

            var label: String {
                switch self {
                case .github: "GitHub Release"
                case .script: "Script"
                case .none: "None — artifacts only"
                }
            }
        }

        nonisolated struct Publish: Codable, Hashable {
            var channel: PublishChannel = .none

            /// `owner/repo` on github.com.
            var githubRepo: String?
            var prerelease: Bool = false

            /// Local checkout of a Homebrew tap whose `Casks/<name>.rb` gets
            /// its version + sha256 rewritten after a GitHub upload.
            var homebrewTapDir: String?

            /// The cask filename stem inside the tap; `nil` derives it from the
            /// app name lowercased.
            var homebrewCask: String?

            /// Channel `.script`: executable run with `RILMAZAFONE_*`
            /// environment describing the finished build.
            var script: String?

            /// Runs after distribution on any channel — the escape hatch for
            /// app-specific tails (CDN purges, notifications, side uploads)
            /// that don't belong in the shared pipeline. Same `RILMAZAFONE_*`
            /// environment as the channel script.
            var postScript: String?

            /// Default release-notes source, repo-relative (e.g. a changelog
            /// excerpt). The publish sheet prefills from it; `-n`/`--notes-file`
            /// on the CLI override it.
            var notesFile: String?

            init() {}

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                self.channel = try container.decodeIfPresent(PublishChannel.self, forKey: .channel) ?? .none
                self.githubRepo = try container.decodeIfPresent(String.self, forKey: .githubRepo)
                self.prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
                self.homebrewTapDir = try container.decodeIfPresent(String.self, forKey: .homebrewTapDir)
                self.homebrewCask = try container.decodeIfPresent(String.self, forKey: .homebrewCask)
                self.script = try container.decodeIfPresent(String.self, forKey: .script)
                self.postScript = try container.decodeIfPresent(String.self, forKey: .postScript)
                self.notesFile = try container.decodeIfPresent(String.self, forKey: .notesFile)
            }
        }
    }

    // MARK: - Resolution

    /// A plan with every path resolved to an absolute URL and every default
    /// filled in, anchored at the `.releaseplan` bundle's location on disk.
    nonisolated struct ResolvedReleasePlan {
        let plan: ReleasePlan
        let planURL: URL

        /// Repository root: `project.path` resolved against the plan's folder,
        /// or the plan's folder itself.
        let repoRoot: URL
        let xcodeprojURL: URL
        let scheme: String
        let appName: String

        /// The `.dmgtemplate` used to build the DMG.
        let designURL: URL

        var pbxprojURL: URL {
            xcodeprojURL.appending(path: "project.pbxproj")
        }

        var versionConstantURL: URL? {
            plan.project.versionConstant.map { repoRoot.appending(path: $0) }
        }

        var entitlementsURL: URL? {
            plan.signing.entitlements.map { repoRoot.appending(path: $0) }
        }

        var provisioningProfileURL: URL? {
            plan.signing.provisioningProfile.map { ReleasePlan.resolve($0, against: repoRoot) }
        }

        var eddsaKeyURL: URL? {
            plan.artifacts.eddsaPrivateKey.map { ReleasePlan.resolve($0, against: repoRoot) }
        }

        var dsymArchiveDirURL: URL? {
            plan.artifacts.dsymArchiveDir.map { ReleasePlan.resolve($0, against: repoRoot) }
        }

        var homebrewTapDirURL: URL? {
            plan.publish.homebrewTapDir.map { ReleasePlan.resolve($0, against: repoRoot) }
        }

        var notesFileURL: URL? {
            plan.publish.notesFile.map { ReleasePlan.resolve($0, against: repoRoot) }
        }

        /// Where finished artifacts land.
        var outputDirURL: URL {
            if let dir = plan.artifacts.outputDir {
                return ReleasePlan.resolve(dir, against: repoRoot)
            }
            return URL.applicationSupportDirectory
                .appending(path: "Rilmazafone/Releases/\(appName)")
        }
    }

    nonisolated enum ReleasePlanError: Error, LocalizedError {
        case xcodeprojNotFound(URL)
        case designNotFound(URL)
        case notAPlan(URL)

        var errorDescription: String? {
            switch self {
            case let .xcodeprojNotFound(url):
                "No .xcodeproj found at \(url.path). Set the project path in the plan."
            case let .designNotFound(url):
                "DMG design not found at \(url.path)."
            case let .notAPlan(url):
                "No plan.json found in \(url.lastPathComponent). Is this a valid .releaseplan?"
            }
        }
    }

    extension ReleasePlan {
        /// Expands `~` and resolves a relative path against a base directory.
        nonisolated static func resolve(_ path: String, against base: URL) -> URL {
            let expanded = NSString(string: path).expandingTildeInPath
            if expanded.hasPrefix("/") {
                return URL(fileURLWithPath: expanded)
            }
            return base.appending(path: expanded).standardizedFileURL
        }

        /// Resolves paths and fills defaults; throws when the project or design
        /// can't be located.
        nonisolated func resolve(planURL: URL) throws -> ResolvedReleasePlan {
            let planFolder = planURL.deletingLastPathComponent()
            let repoRoot = project.path.map { Self.resolve($0, against: planFolder) } ?? planFolder

            let xcodeprojURL: URL
            if let name = project.xcodeproj {
                xcodeprojURL = Self.resolve(name, against: repoRoot)
            } else if let discovered = try? FileManager.default
                .contentsOfDirectory(at: repoRoot, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "xcodeproj" }) {
                xcodeprojURL = discovered
            } else {
                throw ReleasePlanError.xcodeprojNotFound(repoRoot)
            }
            guard FileManager.default.fileExists(atPath: xcodeprojURL.path) else {
                throw ReleasePlanError.xcodeprojNotFound(xcodeprojURL)
            }

            let scheme = project.scheme ?? xcodeprojURL.deletingPathExtension().lastPathComponent
            let appName = project.appName ?? scheme

            let designURL: URL = switch design.source {
            case .embedded:
                planURL.appending(path: ReleasePlanDocument.designFilename)
            case .path:
                Self.resolve(design.path ?? "", against: repoRoot)
            }

            return ResolvedReleasePlan(
                plan: self,
                planURL: planURL,
                repoRoot: repoRoot,
                xcodeprojURL: xcodeprojURL,
                scheme: scheme,
                appName: appName,
                designURL: designURL,
            )
        }
    }
#endif
