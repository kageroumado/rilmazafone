#if !APPSTORE
    import Foundation
    import Testing
    @testable import Rilmazafone

    @Suite("PlanReadiness")
    struct PlanReadinessTests {
        // MARK: - Fixtures

        /// A directory shaped like a repo with an Xcode project in it, since the
        /// repository check resolves against the filesystem.
        static func makeRepo() throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "readiness-\(UUID().uuidString)")
            let project = root.appending(path: "Example.xcodeproj")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Data().write(to: project.appending(path: "project.pbxproj"))
            return root
        }

        /// A plan wired up the way auto-detection leaves one.
        static func configuredPlan(repo: URL) -> ReleasePlan {
            var plan = ReleasePlan()
            plan.project.path = repo.path
            plan.project.scheme = "Example"
            plan.notarization.keychainProfile = "example-notary"
            return plan
        }

        static func detection() -> PlanDetection {
            var detection = PlanDetection()
            detection.schemes = ["Example"]
            detection.identities = ["Developer ID Application: Example (ABCDE12345)"]
            detection.notaryProfileVerified = true
            detection.projectVersion = .init(marketing: "1.2", build: 7)
            return detection
        }

        static func evaluate(
            plan: ReleasePlan,
            detection: PlanDetection,
            repo: URL,
        ) -> PlanReadiness {
            PlanReadiness.evaluate(
                plan: plan,
                detection: detection,
                planURL: repo.appending(path: "Example.releaseplan"),
            )
        }

        // MARK: - Not configured

        /// A brand-new plan has nothing to check yet, and should say so rather than
        /// listing five failures at someone who has not started.
        @Test
        func `A new plan reads as unconfigured rather than as failing`() {
            let readiness = PlanReadiness.evaluate(
                plan: ReleasePlan(), detection: PlanDetection(), planURL: nil,
            )

            #expect(!readiness.isConfigured)
            #expect(!readiness.canBuild)
            #expect(readiness.checks.isEmpty)
            #expect(readiness.summary == "Not configured")
        }

        // MARK: - Blockers

        /// The point of showing this at rest: each of these fails the run at Preflight,
        /// and every one of them is knowable before pressing Build.
        @Test(arguments: [
            ("no scheme", { (p: inout ReleasePlan, _: inout PlanDetection) in p.project.scheme = nil }),
            ("no notary profile", { (p: inout ReleasePlan, _: inout PlanDetection) in p.notarization.keychainProfile = "" }),
            ("notary profile missing", { (_: inout ReleasePlan, d: inout PlanDetection) in d.notaryProfileVerified = false }),
            ("no Developer ID", { (_: inout ReleasePlan, d: inout PlanDetection) in d.identities = [] }),
            ("scheme not in project", { (p: inout ReleasePlan, d: inout PlanDetection) in
                p.project.scheme = "Ghost"
                d.schemes = ["Example"]
            }),
        ])
        func `A missing prerequisite blocks the build`(
            name: String,
            break_: (inout ReleasePlan, inout PlanDetection) -> Void,
        ) throws {
            let repo = try Self.makeRepo()
            defer { try? FileManager.default.removeItem(at: repo) }

            var plan = Self.configuredPlan(repo: repo)
            var detection = Self.detection()
            break_(&plan, &detection)

            let readiness = Self.evaluate(plan: plan, detection: detection, repo: repo)

            #expect(!readiness.canBuild, "\(name) should block the build")
            #expect(!readiness.blocked.isEmpty)
            #expect(readiness.summary.contains("failed"))
        }

        @Test
        func `A fully configured plan is ready`() throws {
            let repo = try Self.makeRepo()
            defer { try? FileManager.default.removeItem(at: repo) }
            let readiness = Self.evaluate(
                plan: Self.configuredPlan(repo: repo), detection: Self.detection(), repo: repo,
            )

            #expect(readiness.isConfigured)
            #expect(readiness.canBuild)
            #expect(readiness.blocked.isEmpty)
            #expect(readiness.warnings.isEmpty)
            #expect(readiness.summary == "Ready to build")
        }

        // MARK: - Warnings

        /// Not every gap stops a run. A project with no `MARKETING_VERSION` still
        /// builds — it just will not bump — so it warns rather than blocks.
        @Test
        func `A missing project version warns without blocking`() throws {
            let repo = try Self.makeRepo()
            defer { try? FileManager.default.removeItem(at: repo) }
            var detection = Self.detection()
            detection.projectVersion = nil

            let readiness = Self.evaluate(
                plan: Self.configuredPlan(repo: repo), detection: detection, repo: repo,
            )

            #expect(readiness.canBuild)
            #expect(readiness.warnings.count == 1)
            #expect(readiness.summary == "Ready, 1 warning")
        }

        /// Detection runs asynchronously; until it has verified the profile the plan is
        /// not known-bad, so it warns rather than accusing.
        @Test
        func `An unverified notary profile warns rather than blocks`() throws {
            let repo = try Self.makeRepo()
            defer { try? FileManager.default.removeItem(at: repo) }
            var detection = Self.detection()
            detection.notaryProfileVerified = nil

            let readiness = Self.evaluate(
                plan: Self.configuredPlan(repo: repo), detection: detection, repo: repo,
            )

            #expect(readiness.canBuild)
            #expect(readiness.warnings.contains { $0.id == "notary" })
        }

        // MARK: - Publish

        /// The publish checks are irrelevant to a plan that does not publish, and
        /// listing them would be five failures nobody asked about.
        @Test
        func `Publish checks apply only when the plan publishes`() throws {
            let repo = try Self.makeRepo()
            defer { try? FileManager.default.removeItem(at: repo) }

            let withoutChannel = Self.evaluate(
                plan: Self.configuredPlan(repo: repo), detection: Self.detection(), repo: repo,
            )
            #expect(!withoutChannel.checks.contains { $0.id == "gh" })

            var plan = Self.configuredPlan(repo: repo)
            plan.publish.channel = .github
            plan.publish.githubRepo = "example/project"

            var detection = Self.detection()
            detection.githubCLI = .init(installed: true, authenticated: true)
            detection.repoVerified = true

            let withChannel = Self.evaluate(plan: plan, detection: detection, repo: repo)
            #expect(withChannel.checks.contains { $0.id == "gh" })
            #expect(withChannel.canBuild)
        }

        @Test
        func `An unauthenticated GitHub CLI blocks a GitHub publish`() throws {
            let repo = try Self.makeRepo()
            defer { try? FileManager.default.removeItem(at: repo) }

            var plan = Self.configuredPlan(repo: repo)
            plan.publish.channel = .github
            plan.publish.githubRepo = "example/project"

            var detection = Self.detection()
            detection.githubCLI = .init(installed: true, authenticated: false)

            let readiness = Self.evaluate(plan: plan, detection: detection, repo: repo)

            #expect(!readiness.canBuild)
            #expect(readiness.blocked.contains { $0.id == "gh" })
        }
    }
#endif
