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

    func testAttemptGuardDoesNotCountOneAttemptTwice() {
        let suiteName = "AttemptGuardDeduplicationTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let guardService = UserDefaultsAttemptGuard(defaults: suite)
        let now = Date(timeIntervalSince1970: 2_000_000)
        let attemptID = UUID()

        let first = guardService.recordAuthenticationFailure(attemptID: attemptID, now: now)
        let duplicate = guardService.recordAuthenticationFailure(attemptID: attemptID, now: now.addingTimeInterval(10))

        XCTAssertEqual(first, duplicate)
    }

    @MainActor
    func testLiveOTPIsSubmittedOnlyAfterChallenge() async throws {
        let tunnel = RecordingTunnelClient()
        let service = VPNConnectionService(passwordStore: MemoryPasswordStore(password: "secret"), attemptGuard: RecordingAttemptGuard(), tunnel: tunnel)
        try await service.connect(profile: VPNProfile(gateway: "vpn.example.test", group: "staff", username: "max"), passwordOverride: nil, otp: "")
        tunnel.status = TunnelStatus(state: .otpRequired, message: "Enter code", attemptID: tunnel.attemptID)
        _ = try await service.refreshStatus()

        try await service.submitOTP("123456")

        XCTAssertEqual(tunnel.submittedOTPs, ["123456"])
        XCTAssertEqual(service.status.state, .authenticating)
    }

    @MainActor
    func testRefreshRecordsAuthenticationFailureOnce() async throws {
        let tunnel = RecordingTunnelClient()
        let guardService = RecordingAttemptGuard()
        let service = VPNConnectionService(passwordStore: MemoryPasswordStore(password: "secret"), attemptGuard: guardService, tunnel: tunnel)
        try await service.connect(profile: VPNProfile(gateway: "vpn.example.test", group: "staff", username: "max"), passwordOverride: nil, otp: "")
        tunnel.authenticationFailure = true

        for _ in 0..<2 { _ = try? await service.refreshStatus() }

        XCTAssertEqual(guardService.recordedAttemptIDs.count, 1)
    }

}

private final class MemoryPasswordStore: PasswordStore {
    var password: String?
    init(password: String?) { self.password = password }
    var hasPassword: Bool { password?.isEmpty == false }
    func read() throws -> String? { password }
    func save(_ password: String) throws { self.password = password }
    func delete() throws { password = nil }
}

private final class RecordingAttemptGuard: AttemptGuard {
    var recordedAttemptIDs: [UUID] = []
    func retryDate(now: Date) -> Date? { nil }
    func recordAuthenticationFailure(attemptID: UUID, now: Date) -> Date {
        if !recordedAttemptIDs.contains(attemptID) { recordedAttemptIDs.append(attemptID) }
        return now.addingTimeInterval(60)
    }
    func resetAfterSuccess() {}
}

@MainActor
private final class RecordingTunnelClient: TunnelClient {
    var status = TunnelStatus(state: .authenticating, message: "Authenticating", attemptID: nil)
    var submittedOTPs: [String] = []
    var authenticationFailure = false
    var attemptID: UUID?
    func discoverGroups(gateway: URL) async throws -> [VPNGroup] { [VPNGroup(id: "staff", label: "Staff")] }
    func connect(request: CiscoAuthenticationRequest) async throws -> TunnelStatus {
        attemptID = request.attemptID
        status.attemptID = request.attemptID
        return status
    }
    func submitOTP(_ value: String) async throws { submittedOTPs.append(value) }
    func disconnect() async throws -> TunnelStatus { .disconnected }
    func currentStatus() async throws -> TunnelStatus {
        if authenticationFailure { throw AuthenticationFailure(message: "Rejected") }
        return status
    }
}
