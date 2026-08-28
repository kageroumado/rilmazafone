#if !APPSTORE
    import Foundation

    // MARK: - Readiness

    /// What Preflight would find, worked out before anyone presses a button.
    ///
    /// Preflight is stage one of eight, so without this the answer to "can I run this?"
    /// only arrives after committing to a run. Every input it checks is already known at
    /// rest: the repository resolved, the scheme detected, the identity in the keychain,
    /// the notary profile verified, `gh` authenticated. This assembles them into the
    /// answer and the plan window shows it while idle.
    nonisolated struct PlanReadiness: Equatable {
        nonisolated struct Check: Equatable, Identifiable {
            enum Status: Equatable {
                /// Satisfied.
                case ok
                /// Runnable, but something downstream will be missing or guessed.
                case warning
                /// A run would fail at Preflight.
                case blocked
            }

            let id: String
            let title: String
            let detail: String
            let status: Status
        }

        var checks: [Check] = []

        /// Whether the plan has enough to configure at all. A brand-new plan has not.
        var isConfigured = false

        var blocked: [Check] {
            checks.filter { $0.status == .blocked }
        }
        var warnings: [Check] {
            checks.filter { $0.status == .warning }
        }

        var canBuild: Bool {
            isConfigured && blocked.isEmpty
        }

        /// One line for the heading: what a run would do, or what stops it.
        var summary: String {
            guard isConfigured else { return "Not configured" }
            if !blocked.isEmpty {
                return blocked.count == 1 ? "1 check failed" : "\(blocked.count) checks failed"
            }
            if !warnings.isEmpty {
                return warnings.count == 1 ? "Ready, 1 warning" : "Ready, \(warnings.count) warnings"
            }
            return "Ready to build"
        }
    }

    // MARK: - Evaluation

    /// `nonisolated`, not merely because the struct is: an extension takes the module's
    /// default isolation unless it says otherwise, and this is pure logic that the plan
    /// window, a background detection pass, or a test may each call from wherever they
    /// happen to be running.
    nonisolated extension PlanReadiness {
        /// Works out the readiness of `plan` from what detection already found. The
        /// publish-side checks only apply when the plan actually publishes somewhere.
        static func evaluate(
            plan: ReleasePlan,
            detection: PlanDetection,
            planURL: URL?,
        ) -> PlanReadiness {
            var readiness = PlanReadiness()

            let resolved = planURL.flatMap { try? plan.resolve(planURL: $0) }
            readiness.isConfigured = resolved != nil || plan.project.scheme != nil

            guard readiness.isConfigured else { return readiness }

            readiness.checks.append(repositoryCheck(resolved: resolved, plan: plan))
            readiness.checks.append(schemeCheck(plan: plan, detection: detection))
            readiness.checks.append(versionCheck(detection: detection))
            readiness.checks.append(signingCheck(plan: plan, detection: detection))
            readiness.checks.append(notaryCheck(plan: plan, detection: detection))

            if plan.publish.channel != .none {
                readiness.checks.append(contentsOf: publishChecks(plan: plan, detection: detection))
            }

            return readiness
        }

        private static func repositoryCheck(
            resolved: ResolvedReleasePlan?,
            plan _: ReleasePlan,
        ) -> Check {
            guard let resolved else {
                return Check(
                    id: "repository",
                    title: "Repository",
                    detail: "No Xcode project found",
                    status: .blocked,
                )
            }
            return Check(
                id: "repository",
                title: "Repository",
                detail: resolved.xcodeprojURL.lastPathComponent,
                status: .ok,
            )
        }

        private static func schemeCheck(
            plan: ReleasePlan,
            detection: PlanDetection,
        ) -> Check {
            guard let scheme = plan.project.scheme, !scheme.isEmpty else {
                return Check(
                    id: "scheme",
                    title: "Scheme",
                    detail: "Not set",
                    status: .blocked,
                )
            }
            // An empty detection list means detection has not finished or the project
            // could not be listed — not that the scheme is wrong.
            let known = detection.schemes.isEmpty || detection.schemes.contains(scheme)
            return Check(
                id: "scheme",
                title: "Scheme",
                detail: known ? scheme : "\(scheme) — not in this project",
                status: known ? .ok : .blocked,
            )
        }

        private static func versionCheck(detection: PlanDetection) -> Check {
            guard let version = detection.projectVersion else {
                return Check(
                    id: "version",
                    title: "Version",
                    detail: "No MARKETING_VERSION found — the bump will be skipped",
                    status: .warning,
                )
            }
            return Check(
                id: "version",
                title: "Version",
                detail: "\(version.marketing) (\(version.build))",
                status: .ok,
            )
        }

        private static func signingCheck(
            plan: ReleasePlan,
            detection: PlanDetection,
        ) -> Check {
            if let identity = plan.signing.identity, !identity.isEmpty {
                let present = detection.identities.isEmpty || detection.identities.contains(identity)
                return Check(
                    id: "signing",
                    title: "Signing",
                    detail: present ? identity : "\(identity) — not in the keychain",
                    status: present ? .ok : .blocked,
                )
            }

            let developerID = detection.identities.first { $0.contains("Developer ID Application") }
            guard let developerID else {
                return Check(
                    id: "signing",
                    title: "Signing",
                    detail: "No Developer ID Application certificate in the keychain",
                    status: .blocked,
                )
            }
            return Check(id: "signing", title: "Signing", detail: developerID, status: .ok)
        }

        private static func notaryCheck(
            plan: ReleasePlan,
            detection: PlanDetection,
        ) -> Check {
            let profile = plan.notarization.keychainProfile
            guard !profile.isEmpty else {
                return Check(
                    id: "notary",
                    title: "Notary profile",
                    detail: "Not set — notarization will fail",
                    status: .blocked,
                )
            }
            switch detection.notaryProfileVerified {
            case true:
                return Check(id: "notary", title: "Notary profile", detail: profile, status: .ok)
            case false:
                return Check(
                    id: "notary",
                    title: "Notary profile",
                    detail: "\(profile) — not found in the keychain",
                    status: .blocked,
                )
            default:
                return Check(
                    id: "notary",
                    title: "Notary profile",
                    detail: "\(profile) — not verified yet",
                    status: .warning,
                )
            }
        }

        private static func publishChecks(
            plan: ReleasePlan,
            detection: PlanDetection,
        ) -> [Check] {
            guard plan.publish.channel == .github else { return [] }

            var checks: [Check] = []

            if let repo = plan.publish.githubRepo, !repo.isEmpty {
                let verified = detection.repoVerified
                checks.append(Check(
                    id: "repo",
                    title: "GitHub repo",
                    detail: verified == false ? "\(repo) — no push access" : repo,
                    status: verified == false ? .blocked : .ok,
                ))
            } else {
                checks.append(Check(
                    id: "repo",
                    title: "GitHub repo",
                    detail: "Not set",
                    status: .blocked,
                ))
            }

            let cli = detection.githubCLI
            if !cli.installed {
                checks.append(Check(
                    id: "gh",
                    title: "GitHub CLI",
                    detail: "gh is not installed",
                    status: .blocked,
                ))
            } else if !cli.authenticated {
                checks.append(Check(
                    id: "gh",
                    title: "GitHub CLI",
                    detail: "gh is not authenticated — run gh auth login",
                    status: .blocked,
                ))
            } else {
                checks.append(Check(
                    id: "gh",
                    title: "GitHub CLI",
                    detail: "Authenticated",
                    status: .ok,
                ))
            }

            return checks
        }
    }
#endif
