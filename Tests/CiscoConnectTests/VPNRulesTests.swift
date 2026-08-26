import XCTest
@testable import CiscoConnect

final class VPNRulesTests: XCTestCase {
    func testProfileNormalizesGatewayAndValidatesPassword() {
        let profile = VPNProfile(gateway: " vpn.example.test/ ", group: " staff ", username: " max ")

        XCTAssertEqual(profile.normalized().gateway, "https://vpn.example.test")
        XCTAssertEqual(profile.normalized().group, "staff")
        XCTAssertEqual(profile.normalized().username, "max")
        XCTAssertEqual(profile.validationErrors(hasStoredPassword: false), ["Save the primary VPN password in Keychain."])
    }

    func testAuthenticationRequestKeepsOtpInChallengeField() throws {
        let request = try CiscoAuthenticationRequest(
            profile: VPNProfile(gateway: "vpn.example.test", group: "staff", username: "max"),
            password: "secret",
            otp: "123456",
            attemptID: UUID()
        )

        XCTAssertEqual(
            request.formEntries,
            [
                CiscoFormEntry(form: "main", option: "username", value: "max"),
                CiscoFormEntry(form: "main", option: "password", value: "secret"),
                CiscoFormEntry(form: "main", option: "group_list", value: "staff"),
                CiscoFormEntry(form: "challenge", option: "answer", value: "123456"),
            ]
        )
    }

    func testAttemptGuardAppliesFirstThenRepeatedCooldown() {
        let suiteName = "AttemptGuardTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let guardService = UserDefaultsAttemptGuard(defaults: suite)
        let now = Date(timeIntervalSince1970: 1_000_000)

        let first = guardService.recordAuthenticationFailure(attemptID: UUID(), now: now)
        XCTAssertEqual(first.timeIntervalSince(now), 60)
        let second = guardService.recordAuthenticationFailure(attemptID: UUID(), now: now.addingTimeInterval(10))
        XCTAssertEqual(second.timeIntervalSince(now.addingTimeInterval(10)), 30 * 60)
    }

}
