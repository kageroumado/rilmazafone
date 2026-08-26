#if !APPSTORE
    import Foundation

    // MARK: - Build Record

    /// The durable result of a Build phase: what was built, where the artifacts
    /// are, and whether notarization is complete. Publish consumes the latest
    /// record — minutes or days later — which is what makes the two phases
    /// dissociable.
    ///
    /// Records live in Application Support keyed by the plan's stable identity,
    /// not inside the document: building must not dirty the plan file or churn
    /// the repo.
    nonisolated struct BuildRecord: Codable, Sendable {
        var planIdentity: UUID
        var appName: String
        var version: String
        var build: Int
        var createdAt: Date

        /// The finished DMG (stapled when `notarized`).
        var dmgPath: String
        var dmgSizeBytes: Int64

        /// The Xcode Organizer archive this build came from (kept, not
        /// deleted — Organizer owns its history).
        var archivePath: String?
        /// Extra artifacts: app zip, `.sig`, dSYM zip.
        var extraArtifacts: [String] = []

        var notarized: Bool
        /// Pending `notarytool` submission from an async run; cleared by staple.
        var pendingSubmissionID: String?

        /// Set once a publish run has shipped this record.
        var publishedURL: String?

        var artifactURLs: [URL] {
            ([dmgPath] + extraArtifacts).map { URL(fileURLWithPath: $0) }
        }

        var dmgExists: Bool {
            FileManager.default.fileExists(atPath: dmgPath)
        }
    }

    // MARK: - Store

    /// Reads and writes the per-plan record under Application Support, keyed
    /// by the plan's stable identity.
    nonisolated enum BuildRecordStore {
        static func recordURL(for planIdentity: UUID) -> URL {
            URL.applicationSupportDirectory
                .appending(path: "Rilmazafone/Records/\(planIdentity.uuidString).json")
        }

        static func load(planIdentity: UUID) -> BuildRecord? {
            guard let data = try? Data(contentsOf: recordURL(for: planIdentity)) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(BuildRecord.self, from: data)
        }

        static func save(_ record: BuildRecord) throws {
            let url = recordURL(for: record.planIdentity)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: url)
        }
    }
#endif
