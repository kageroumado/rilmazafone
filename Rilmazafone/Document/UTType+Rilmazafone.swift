import UniformTypeIdentifiers

extension UTType {
    nonisolated static let rilmazafoneDocument = UTType(
        exportedAs: "glass.kagerou.rilmazafone.dmg-template",
    )

    #if !APPSTORE
        /// The `.releaseplan` package. GitHub build only — the App Store
        /// build's Info.plist deliberately does not declare this type, since
        /// the sandbox can't run the pipeline that gives the document meaning.
        nonisolated static let rilmazafoneReleasePlan = UTType(
            exportedAs: "glass.kagerou.rilmazafone.release-plan",
        )
    #endif
}
