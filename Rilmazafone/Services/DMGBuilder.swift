import Foundation
import Security

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
    }

    /// DER-encoded content of the id-kp-codeSigning extended-key-usage OID
    /// (`1.3.6.1.5.5.7.3.3`), used to filter identities to signing-capable ones —
    /// the same set `security find-identity -v -p codesigning` reports.
    private static let codeSigningEKUBytes = Data([0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x03])

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
        let tempPath = tempDir.appending(path: "rilmazafone-writable-\(UUID().uuidString).dmg")

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

    /// Mounts a DMG read-only for inspection and returns the mount point URL.
    ///
    /// Used by the import flow: the image is never modified, so `-readonly`
    /// keeps the attach safe for images of any format (including compressed
    /// ones, which cannot be mounted writable anyway).
    static func attachReadOnly(_ dmgPath: URL) async throws -> URL {
        let tempMount = FileManager.default.temporaryDirectory
            .appending(path: "rilmazafone-import-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: tempMount, withIntermediateDirectories: true)

        do {
            try await ProcessRunner.run(
                Executable.hdiutil,
                arguments: [
                    "attach", dmgPath.path,
                    "-readonly",
                    "-noautoopen",
                    "-nobrowse",
                    "-noverify",
                    "-mountpoint", tempMount.path,
                ]
            )
        } catch {
            try? FileManager.default.removeItem(at: tempMount)
            throw error
        }

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

    /// Copies source items into the mounted DMG volume, holding security-scoped
    /// access to each copy item's source for the duration of its copy.
    static func copyItems(
        _ items: [CanvasItem],
        to mountPoint: URL,
        documentURL: URL? = nil
    ) throws {
        let fileManager = FileManager.default
        for item in items {
            let destination = mountPoint.appending(path: item.label)
            switch item.kind {
            case .applicationsSymlink:
                // String-path variant stores "/Applications" verbatim; the URL variant
                // would resolve/rewrite the destination.
                try fileManager.createSymbolicLink(
                    atPath: destination.path,
                    withDestinationPath: "/Applications"
                )

            case .app, .file, .folder:
                if item.linkType == .symlink {
                    guard let target = item.sourcePath, !target.isEmpty else { continue }
                    try fileManager.createSymbolicLink(
                        atPath: destination.path,
                        withDestinationPath: target
                    )
                } else {
                    // The scope must span the entire copy of the item, not just
                    // URL resolution.
                    try SourceAccess.withScope(item: item, documentURL: documentURL) { source in
                        guard let source, fileManager.fileExists(atPath: source.path) else {
                            throw ValidationError.missingSourceFile(item.sourcePath ?? item.label)
                        }
                        // copyItem preserves symlinks inside .app bundles.
                        try fileManager.copyItem(at: source, to: destination)
                    }
                }
            }
        }
    }

    /// Copies the background image into the hidden .background directory on the volume.
    static func copyBackground(
        named imageName: String,
        from assetsDirectory: URL,
        to mountPoint: URL
    ) throws {
        let bgDir = mountPoint.appending(path: ".background")

        try FileManager.default.createDirectory(at: bgDir, withIntermediateDirectories: true)

        let sourceImage = assetsDirectory.appending(path: imageName)
        let destImage = bgDir.appending(path: imageName)

        try FileManager.default.copyItem(at: sourceImage, to: destImage)

        // Set the invisible flag on .background directory
        try FinderInfo.setInvisible(at: bgDir)
    }

    /// Sets the volume icon on the mounted DMG.
    static func setVolumeIcon(
        icnsData: Data,
        mountPoint: URL
    ) async throws {
        let iconPath = mountPoint.appending(path: ".VolumeIcon.icns")
        try icnsData.write(to: iconPath)

        // Set the custom icon flag on the volume root
        try FinderInfo.setCustomIconFlag(at: mountPoint.path)

        // Make the icon file invisible to Finder (kIsInvisible flag).
        // This prevents it from appearing even with "Show Hidden Files"
        // and excludes it from scroll extent calculations.
        try FinderInfo.setInvisible(at: iconPath)
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
        let resolvedIdentity = try identity ?? resolveSigningIdentity()

        try await ProcessRunner.run(
            Executable.codesign,
            arguments: [
                "--sign", resolvedIdentity,
                dmgPath.path,
            ]
        )
    }

    /// Lists the common names of keychain identities capable of code signing —
    /// the set `security find-identity -v -p codesigning` reports.
    static func listSigningIdentities() -> [String] {
        signingIdentities().map(\.name)
    }

    /// Extracts the signing authority from a signed app bundle.
    ///
    /// Returns the leaf certificate's common name
    /// (e.g. "Developer ID Application: Name (TEAM)") or nil if the app is unsigned
    /// or its signature cannot be read.
    static func signingAuthority(of appURL: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode
        else { return nil }

        var infoRef: CFDictionary?
        guard SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef
        ) == errSecSuccess,
            let info = infoRef as? [String: Any],
            let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
            let leaf = certificates.first
        else { return nil }

        return commonName(of: leaf)
    }

    /// Finds the keychain identity name matching a signing authority.
    /// The authority must appear among the keychain's codesigning identities.
    static func findMatchingKeychainIdentity(authority: String) -> String? {
        let names = listSigningIdentities()
        return names.first { $0 == authority } ?? names.first { $0.contains(authority) }
    }

    /// Searches the keychain for a suitable signing identity, preferring
    /// distribution certificates over development ones.
    ///
    /// Fail-closed: when no identity matches a known Apple prefix this throws
    /// rather than falling back to an arbitrary code-signing certificate —
    /// silently signing with a random (e.g. self-signed) identity would produce
    /// a "successful" build that Gatekeeper rejects on other Macs. A non-Apple
    /// identity can still be used by selecting it explicitly.
    static func resolveSigningIdentity() throws -> String {
        let names = listSigningIdentities()
        let preferredPrefixes = [
            "Developer ID Application",
            "Apple Distribution",
            "Apple Development",
            "Mac Developer",
        ]

        for prefix in preferredPrefixes {
            if let match = names.first(where: { $0.hasPrefix(prefix) }) {
                return match
            }
        }

        throw DMGError.noSigningIdentity
    }

    // MARK: - Identity Discovery

    /// A keychain identity capable of code signing, paired with its display name.
    private struct SigningIdentity {
        let name: String
        let identity: SecIdentity
    }

    /// Queries the keychain for identities whose leaf certificate is valid for code
    /// signing, reproducing the filter applied by
    /// `security find-identity -v -p codesigning`: the id-kp-codeSigning EKU
    /// plus the `-v` validity evaluation, so expired, revoked, and untrusted
    /// identities are never listed, matched, or auto-selected.
    private static func signingIdentities() -> [SigningIdentity] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            // kCFNull means "valid now" — drops expired certificates at the query.
            kSecMatchValidOnDate as String: kCFNull as Any,
            kSecReturnRef as String: true,
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity]
        else { return [] }

        return identities.compactMap { identity in
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate,
                  canSignCode(certificate),
                  isTrustedForCodeSigning(certificate),
                  let name = commonName(of: certificate)
            else { return nil }
            return SigningIdentity(name: name, identity: identity)
        }
    }

    /// Whether the certificate evaluates as trusted under the Apple code-signing
    /// policy right now — the chain/revocation/trust half of `find-identity -v`
    /// that date matching alone does not cover. Honors user trust settings, so a
    /// deliberately trusted self-signed signing certificate still qualifies.
    private static func isTrustedForCodeSigning(_ certificate: SecCertificate) -> Bool {
        guard let policy = SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, nil) else {
            return false
        }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess,
              let trust
        else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }

    /// Whether a certificate's extended key usage includes id-kp-codeSigning.
    private static func canSignCode(_ certificate: SecCertificate) -> Bool {
        var error: Unmanaged<CFError>?
        guard let values = SecCertificateCopyValues(
            certificate, [kSecOIDExtendedKeyUsage] as CFArray, &error
        ) as? [String: Any],
            let eku = values[kSecOIDExtendedKeyUsage as String] as? [String: Any],
            let usages = eku[kSecPropertyKeyValue as String] as? [Data]
        else { return false }

        return usages.contains(codeSigningEKUBytes)
    }

    /// The certificate's common name, or nil if it has none.
    private static func commonName(of certificate: SecCertificate) -> String? {
        var name: CFString?
        guard SecCertificateCopyCommonName(certificate, &name) == errSecSuccess else { return nil }
        return name as String?
    }
}
