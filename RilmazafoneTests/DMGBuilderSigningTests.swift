import Foundation
import Testing
@testable import Rilmazafone

/// Smoke tests for the in-process Security.framework signing queries. Identity
/// contents are machine-specific, so these assert only invariants that hold on any
/// Mac rather than exact identity names.
@Suite("DMGBuilder signing")
struct DMGBuilderSigningTests {
    @Test("signingAuthority is nil for a nonexistent path")
    func authorityNonexistent() {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).app")
        #expect(DMGBuilder.signingAuthority(of: url) == nil)
    }

    @Test("signingAuthority reads a signed system app's leaf certificate")
    func authoritySystemApp() throws {
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        try #require(FileManager.default.fileExists(atPath: textEdit.path))
        let authority = DMGBuilder.signingAuthority(of: textEdit)
        #expect(authority != nil)
        #expect(authority?.isEmpty == false)
    }

    @Test("listSigningIdentities excludes installer certificates")
    func identitiesExcludeInstallers() {
        // The code-signing EKU filter must never surface installer identities,
        // which `security find-identity -v -p codesigning` also omits.
        for name in DMGBuilder.listSigningIdentities() {
            #expect(!name.contains("Installer"), "unexpected installer identity: \(name)")
        }
    }

    @Test("findMatchingKeychainIdentity returns nil for an unknown authority")
    func matchUnknownAuthority() {
        #expect(DMGBuilder.findMatchingKeychainIdentity(authority: "No Such Authority \(UUID())") == nil)
    }
}
