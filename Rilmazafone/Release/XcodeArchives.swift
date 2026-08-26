#if !APPSTORE
    import Foundation

    // MARK: - Xcode Archives

    /// Reads and writes Xcode Organizer's archive store
    /// (`~/Library/Developer/Xcode/Archives/<yyyy-MM-dd>/…​.xcarchive`), so
    /// release builds land where Organizer shows them and existing archives of
    /// the same app can be reused instead of rebuilding.
    nonisolated enum XcodeArchives {
        static var archivesRoot: URL {
            URL.homeDirectory.appending(path: "Library/Developer/Xcode/Archives")
        }

        nonisolated struct Entry: Sendable, Equatable {
            let url: URL
            let appName: String
            let creationDate: Date
            let version: String?
            let build: String?

            var displayLine: String {
                var line = creationDate.formatted(date: .abbreviated, time: .shortened)
                if let version {
                    line += " · v\(version)\(build.map { " (\($0))" } ?? "")"
                }
                return line
            }
        }

        /// Where a fresh archive for this app goes — the same per-day layout
        /// Xcode uses, so Organizer lists it.
        static func newArchiveURL(appName: String, date: Date = Date()) -> URL {
            let day = date.formatted(.iso8601.year().month().day())
            let stamp = date.formatted(
                Date.FormatStyle()
                    .year().month(.twoDigits).day(.twoDigits)
                    .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits),
            ).replacingOccurrences(of: ":", with: ".")
            return archivesRoot
                .appending(path: day)
                .appending(path: "\(appName) \(stamp).xcarchive")
        }

        /// Archives of this app, newest first, matched by the archived
        /// product's name — the same association Organizer makes.
        static func archives(appName: String) -> [Entry] {
            let fm = FileManager.default
            guard let days = try? fm.contentsOfDirectory(
                at: archivesRoot, includingPropertiesForKeys: nil,
            ) else { return [] }

            var entries: [Entry] = []
            for day in days {
                guard let archives = try? fm.contentsOfDirectory(
                    at: day, includingPropertiesForKeys: nil,
                ) else { continue }
                for archive in archives where archive.pathExtension == "xcarchive" {
                    guard let entry = read(archiveURL: archive), entry.appName == appName else {
                        continue
                    }
                    entries.append(entry)
                }
            }
            return entries.sorted { $0.creationDate > $1.creationDate }
        }

        static func latest(appName: String) -> Entry? {
            archives(appName: appName).first
        }

        /// The archived `.app` inside an archive, or `nil` when absent.
        static func applicationURL(in archiveURL: URL, appName: String) -> URL? {
            let url = archiveURL.appending(path: "Products/Applications/\(appName).app")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        private static func read(archiveURL: URL) -> Entry? {
            let infoURL = archiveURL.appending(path: "Info.plist")
            guard let data = try? Data(contentsOf: infoURL),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, format: nil,
                  ) as? [String: Any]
            else { return nil }

            let properties = plist["ApplicationProperties"] as? [String: Any]
            let appPath = properties?["ApplicationPath"] as? String
            let appName = appPath.map {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
            } ?? (plist["Name"] as? String ?? archiveURL.deletingPathExtension().lastPathComponent)

            return Entry(
                url: archiveURL,
                appName: appName,
                creationDate: plist["CreationDate"] as? Date ?? .distantPast,
                version: properties?["CFBundleShortVersionString"] as? String,
                build: properties?["CFBundleVersion"] as? String,
            )
        }
    }
#endif
