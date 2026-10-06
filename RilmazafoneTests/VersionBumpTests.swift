#if !APPSTORE
    import Testing
    @testable import Rilmazafone

    @Suite("Version bump")
    struct VersionBumpTests {
        @Test
        func `a minor bump always yields three components`() {
            #expect(PlanAutoDetection.bumped("1.8", policy: .minor) == "1.9.0")
            #expect(PlanAutoDetection.bumped("1.8.3", policy: .minor) == "1.9.0")
            #expect(PlanAutoDetection.bumped("2", policy: .minor) == "2.1.0")
        }

        @Test
        func `a patch bump pads a two-part version first`() {
            #expect(PlanAutoDetection.bumped("1.8", policy: .patch) == "1.8.1")
            #expect(PlanAutoDetection.bumped("1.8.1", policy: .patch) == "1.8.2")
        }

        @Test
        func `an explicit version is padded to three components`() {
            #expect(PlanAutoDetection.semantic("0.30") == "0.30.0")
            #expect(PlanAutoDetection.semantic("1.9.2") == "1.9.2")
        }
    }
#endif
