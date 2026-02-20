import Foundation

/// Wraps `hdiutil` and `codesign` to create, mount, convert, and sign DMG images.
nonisolated enum DMGBuilder {
    nonisolated enum DMGError: Error, LocalizedError {
        case mountPointNotFound
        case conversionFailed(String)
        case noSigningIdentity
        case detachFailed(String)

        var errorDescription: String? {
            switch self {
            case .mountPointNotFound:
                "Could not determine mount point from hdiutil output."
            case let .conversionFailed(detail):
                "DMG conversion failed: \(detail)"
            case .noSigningIdentity:
                "No code signing identity found in keychain."
            case let .detachFailed(detail):
                "Failed to unmount volume: \(detail)"
            }
        }
    }

    // MARK: - Paths

    private enum Executable {
        static let hdiutil = "/usr/bin/hdiutil"
        static let codesign = "/usr/bin/codesign"
        static let setFile = "/usr/bin/SetFile"
        static let ln = "/bin/ln"
        static let cp = "/bin/cp"
        static let mkdir = "/bin/mkdir"
        static let security = "/usr/bin/security"
    }

    /// Maximum retries for detach when the device is busy.
    private static let detachRetries = 5

    // MARK: - Create

    /// Creates a blank writable DMG with the specified filesystem.
    static func createWritableImage(
        volumeName: String,
        size: String,
        filesystem: DMGFilesystem = .hfsPlus
    ) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let tempPath = tempDir.appending(path: "\(UUID().uuidString).dmg")

        try await ProcessRunner.run(
            Executable.hdiutil,
            arguments: [
                "create",
                "-ov",
                "-size", size,
                "-volname", volumeName,
                "-fs", filesystem.rawValue,
                tempPath.path,
            ]
        )

        return tempPath
    }

    // MARK: - Attach / Detach

    /// Mounts a DMG and returns the mount point URL.
    static func attach(_ dmgPath: URL) async throws -> URL {
        let tempMount = FileManager.default.temporaryDirectory
            .appending(path: "rilmazafone-mount-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: tempMount, withIntermediateDirectories: true)

        try await ProcessRunner.run(
            Executable.hdiutil,
            arguments: [
                "attach", dmgPath.path,
                "-noautoopen",
                "-nobrowse",
                "-noverify",
                "-mountpoint", tempMount.path,
            ]
        )

        return tempMount
    }

    /// Unmounts a DMG volume with retry on "resource busy".
    static func detach(_ mountPoint: URL) async throws {
        for attempt in 0 ..< detachRetries {
            do {
                try await ProcessRunner.run(
                    Executable.hdiutil,
                    arguments: ["detach", mountPoint.path, "-force"]
                )
                return
            } catch let error as ProcessRunner.ProcessError where error.exitCode == 16 {
                // Exit code 16 = resource busy; retry with backoff
                if attempt < detachRetries - 1 {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 500_000_000 // 0.5s, 1s, 2s, 4s
                    try await Task.sleep(nanoseconds: delay)
                } else {
                    throw DMGError.detachFailed(error.stderr)
                }
            }
        }
    }

    // MARK: - Convert

    /// Converts a DMG from one format to another.
    static func convert(
        source: URL,
        destination: URL,
        format: DMGImageFormat
    ) async throws {
        // Remove destination if it exists (hdiutil won't overwrite without -ov)
        try? FileManager.default.removeItem(at: destination)

        var arguments = [
            "convert", source.path,
            "-ov",
            "-format", format.rawValue,
        ]

        // zlib-level only applies to UDZO (zlib-compressed) format
        if format == .udzo {
            arguments += ["-imagekey", "zlib-level=9"]
        }

        arguments += ["-o", destination.path]

        try await ProcessRunner.run(Executable.hdiutil, arguments: arguments)
    }

    // MARK: - Content Operations

    /// Copies source items into the mounted DMG volume.
    static func copyItems(
        _ items: [CanvasItem],
        to mountPoint: URL
    ) async throws {
        for item in items {
            switch item.kind {
            case .applicationsSymlink:
                try await ProcessRunner.run(
                    Executable.ln,
                    arguments: [
                        "-s", "/Applications",
                        mountPoint.appending(path: item.label).path,
                    ]
                )

            case .app, .file, .folder:
                if item.linkType == .symlink {
                    guard let target = item.sourcePath, !target.isEmpty else { continue }
                    try await ProcessRunner.run(
                        Executable.ln,
                        arguments: [
                            "-s", target,
                            mountPoint.appending(path: item.label).path,
                        ]
                    )
                } else {
                    guard let sourcePath = item.sourcePath else { continue }
                    let source = URL(fileURLWithPath: sourcePath)
                    guard FileManager.default.fileExists(atPath: source.path) else {
                        throw ValidationError.missingSourceFile(sourcePath)
                    }
                    try await ProcessRunner.run(
                        Executable.cp,
                        arguments: [
                            "-R",
                            source.path,
                            mountPoint.appending(path: item.label).path,
                        ]
                    )
                }
            }
        }
    }

    /// Copies the background image into the hidden .background directory on the volume.
    static func copyBackground(
        named imageName: String,
        from assetsDirectory: URL,
        to mountPoint: URL
    ) async throws {
        let bgDir = mountPoint.appending(path: ".background")

        try await ProcessRunner.run(
            Executable.mkdir,
            arguments: ["-p", bgDir.path]
        )

        let sourceImage = assetsDirectory.appending(path: imageName)
        let destImage = bgDir.appending(path: imageName)

        try await ProcessRunner.run(
            Executable.cp,
            arguments: [sourceImage.path, destImage.path]
        )

        // Set the invisible flag on .background directory
        try await ProcessRunner.run(
            Executable.setFile,
            arguments: ["-a", "V", bgDir.path]
        )
    }

    /// Sets the volume icon on the mounted DMG.
    static func setVolumeIcon(
        icnsData: Data,
        mountPoint: URL
    ) async throws {
        let iconPath = mountPoint.appending(path: ".VolumeIcon.icns")
        try icnsData.write(to: iconPath)

        // Set the custom icon flag on the volume root
        try await ProcessRunner.run(
            Executable.setFile,
            arguments: ["-a", "C", mountPoint.path]
        )

        // Make the icon file invisible to Finder (kIsInvisible flag).
        // This prevents it from appearing even with "Show Hidden Files"
        // and excludes it from scroll extent calculations.
        try await ProcessRunner.run(
            Executable.setFile,
            arguments: ["-a", "V", iconPath.path]
        )
    }

    // MARK: - Bless

    /// Blesses the volume so Finder opens it correctly.
    ///
    /// Only applicable for HFS+ volumes. APFS does not support `bless`.
    /// On arm64 Macs, `--openfolder` is not supported.
    static func bless(folder: URL) async throws {
        var arguments = ["--folder", folder.path]

        #if arch(x86_64)
            arguments += ["--openfolder", folder.path]
        #endif

        try await ProcessRunner.run("/usr/sbin/bless", arguments: arguments)
    }

    // MARK: - Code Signing

    /// Code signs the DMG. If identity is nil, auto-detects from keychain.
    static func codeSign(
        dmgPath: URL,
        identity: String?
    ) async throws {
        let resolvedIdentity: String = if let identity {
            identity
        } else {
            try await resolveSigningIdentity()
        }

        try await ProcessRunner.run(
            Executable.codesign,
            arguments: [
                "--sign", resolvedIdentity,
                dmgPath.path,
            ]
        )
    }

    /// Extracts the signing authority from a signed app bundle.
    /// Returns the identity name (e.g. "Developer ID Application: Name (TEAM)")
    /// or nil if the app is unsigned.
    static func signingAuthority(of appURL: URL) async -> String? {
        // codesign -d writes to stderr; exits non-zero for unsigned apps
        guard let result = try? await ProcessRunner.run(
            Executable.codesign,
            arguments: ["-d", "--verbose=1", appURL.path]
        ) else { return nil }

        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        for line in stderr.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Authority=") {
                return String(trimmed.dropFirst("Authority=".count))
            }
        }
        return nil
    }

    /// Finds the keychain identity name matching a signing authority.
    /// The authority must appear in the keychain's codesigning identities.
    static func findMatchingKeychainIdentity(authority: String) async -> String? {
        guard let output = try? await ProcessRunner.runString(
            Executable.security,
            arguments: ["find-identity", "-v", "-p", "codesigning"]
        ) else { return nil }

        for line in output.components(separatedBy: .newlines) {
            // Lines look like: 1) ABC123... "Developer ID Application: Name (TEAM)"
            guard line.contains(authority),
                  let firstQuote = line.firstIndex(of: "\"") else { continue }
            let afterQuote = line.index(after: firstQuote)
            guard afterQuote < line.endIndex,
                  let lastQuote = line[afterQuote...].firstIndex(of: "\"") else { continue }
            return String(line[afterQuote ..< lastQuote])
        }
        return nil
    }

    /// Searches the keychain for a suitable signing identity.
    static func resolveSigningIdentity() async throws -> String {
        let output = try await ProcessRunner.runString(
            Executable.security,
            arguments: [
                "find-identity", "-v", "-p", "codesigning",
            ]
        )

        let preferredPrefixes = [
            "Developer ID Application",
            "Mac Developer",
            "Apple Development",
        ]

        for prefix in preferredPrefixes {
            for line in output.components(separatedBy: .newlines) {
                if line.contains(prefix),
                   let hashRange = line.range(of: "[A-F0-9]{40}", options: .regularExpression) {
                    return String(line[hashRange])
                }
            }
        }

        throw DMGError.noSigningIdentity
    }
}
