import Foundation
import Testing
@testable import Rilmazafone

/// Smoke tests for the in-process Security.framework signing queries. Identity
/// contents are machine-specific, so these assert only invariants that hold on any
/// Mac rather than exact identity names.
@Suite("DMGBuilder signing")
struct DMGBuilderSigningTests {
    @Test
    func `signingAuthority is nil for a nonexistent path`() {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).app")
        #expect(DMGBuilder.signingAuthority(of: url) == nil)
    }

    @Test
    func `signingAuthority reads a signed system app's leaf certificate`() throws {
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        try #require(FileManager.default.fileExists(atPath: textEdit.path))
        let authority = DMGBuilder.signingAuthority(of: textEdit)
        #expect(authority != nil)
        #expect(authority?.isEmpty == false)
    }

    @Test
    func `listSigningIdentities excludes installer certificates`() {
        // The code-signing EKU filter must never surface installer identities,
        // which `security find-identity -v -p codesigning` also omits.
        for name in DMGBuilder.listSigningIdentities() {
            #expect(!name.contains("Installer"), "unexpected installer identity: \(name)")
        }
    }

    @Test
    func `findMatchingKeychainIdentity returns nil for an unknown authority`() {
        #expect(DMGBuilder.findMatchingKeychainIdentity(authority: "No Such Authority \(UUID())") == nil)
    }

    @Test
    func `listSigningIdentities matches security find-identity -v`() async throws {
        // The Security.framework port must reproduce the reference tool's
        // *valid* identity set — same EKU filter, same validity evaluation.
        // In particular an expired or untrusted certificate in the keychain
        // must be absent from both lists.
        let result = try await ProcessRunner.run(
            "/usr/bin/security",
            arguments: ["find-identity", "-v", "-p", "codesigning"],
        )
        let output = try #require(String(bytes: result.stdout, encoding: .utf8))
        // Lines look like: `  1) <40-hex-SHA1> "Common Name"`.
        let referenceNames = output
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard let start = line.firstIndex(of: "\""),
                      let end = line.lastIndex(of: "\""),
                      start < end
                else { return nil }
                return String(line[line.index(after: start) ..< end])
            }
        #expect(DMGBuilder.listSigningIdentities().sorted() == referenceNames.sorted())
    }
}
