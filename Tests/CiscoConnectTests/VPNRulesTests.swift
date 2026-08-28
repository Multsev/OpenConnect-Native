import XCTest
@testable import CiscoConnect

final class VPNRulesTests: XCTestCase {
    func testHelperAvailabilityWaiterRecoversFromLaunchRace() async throws {
        let waiter = HelperAvailabilityWaiter(attempts: 3, retryDelay: .zero)
        var pingCount = 0

        try await waiter.waitUntilAvailable {
            pingCount += 1
            if pingCount == 1 { throw VPNError.helperFailure("listener is starting") }
        }

        XCTAssertEqual(pingCount, 2)
    }

    func testHelperAvailabilityWaiterStopsAfterLimit() async {
        let waiter = HelperAvailabilityWaiter(attempts: 3, retryDelay: .zero)
        var pingCount = 0

        do {
            try await waiter.waitUntilAvailable {
                pingCount += 1
                throw VPNError.helperFailure("unavailable")
            }
            XCTFail("Expected the helper availability check to fail")
        } catch {
            XCTAssertEqual(pingCount, 3)
        }
    }

    func testProfileNormalizesGatewayAndValidatesPassword() {
        let profile = VPNProfile(gateway: " vpn.example.test/ ", group: " staff ", username: " max ")

        XCTAssertEqual(profile.normalized().gateway, "https://vpn.example.test")
        XCTAssertEqual(profile.normalized().group, "staff")
        XCTAssertEqual(profile.normalized().username, "max")
        XCTAssertEqual(profile.validationErrors(hasStoredPassword: false), ["Save the primary VPN password in Keychain."])
    }

    func testMenuBarAppearanceReflectsTunnelState() {
        XCTAssertEqual(MenuBarIconAppearance(tunnelState: .disconnected), .offline)
        XCTAssertEqual(MenuBarIconAppearance(tunnelState: .connecting), .working)
        XCTAssertEqual(MenuBarIconAppearance(tunnelState: .authenticating), .working)
        XCTAssertEqual(MenuBarIconAppearance(tunnelState: .otpRequired), .working)
        XCTAssertEqual(MenuBarIconAppearance(tunnelState: .disconnecting), .working)
        XCTAssertEqual(MenuBarIconAppearance(tunnelState: .connected), .online)
        XCTAssertEqual(MenuBarIconAppearance(tunnelState: .sessionExpired), .expired)
        XCTAssertEqual(MenuBarIconAppearance(tunnelState: .failed), .error)
    }

    func testProfileFieldsAreLockedThroughoutAnActiveConnection() {
        XCTAssertFalse(TunnelState.disconnected.locksProfileFields)
        XCTAssertTrue(TunnelState.connecting.locksProfileFields)
        XCTAssertTrue(TunnelState.authenticating.locksProfileFields)
        XCTAssertTrue(TunnelState.otpRequired.locksProfileFields)
        XCTAssertTrue(TunnelState.connected.locksProfileFields)
        XCTAssertTrue(TunnelState.disconnecting.locksProfileFields)
        XCTAssertFalse(TunnelState.sessionExpired.locksProfileFields)
        XCTAssertFalse(TunnelState.failed.locksProfileFields)
    }

    func testSessionPolicyFormatsServerLimitsAndWarningThreshold() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let expiration = now.addingTimeInterval(2 * 60 * 60 + 58 * 60 + 30)
        let policy = VPNSessionPolicy(expirationDate: expiration, idleTimeout: 30 * 60)

        XCTAssertEqual(policy.remainingDescription(at: now), "2 ч 58 мин")
        XCTAssertEqual(policy.idleTimeoutDescription, "30 мин")
        XCTAssertFalse(policy.isExpiringSoon(at: now))
        XCTAssertTrue(policy.isExpiringSoon(at: expiration.addingTimeInterval(-10 * 60)))
        XCTAssertTrue(policy.hasExpired(at: expiration))
    }

    func testNetworkInfoReadsAndNormalizesHelperPayload() {
        let info = VPNNetworkInfo(propertyList: [
            "available": true,
            "includedRoutes": ["10.0.0.0/8", " 10.0.0.0/8 ", ""],
            "excludedRoutes": ["192.168.0.0/16"],
            "domains": ["corp.example.test", " corp.example.test"],
            "dnsServers": ["10.1.0.53"],
            "nbnsServers": ["10.1.0.54"],
            "vpnAddresses": ["10.20.30.40"],
            "vpnNetmasks": ["255.255.255.0"],
            "proxyPAC": "https://proxy.example.test/pac",
            "mtu": 1390,
            "gatewayAddress": "203.0.113.8",
            "interfaceName": "utun7",
        ])

        XCTAssertTrue(info.usesSplitTunnel)
        XCTAssertEqual(info.includedRoutes, ["10.0.0.0/8"])
        XCTAssertEqual(info.excludedRoutes, ["192.168.0.0/16"])
        XCTAssertEqual(info.domains, ["corp.example.test"])
        XCTAssertEqual(info.dnsServers, ["10.1.0.53"])
        XCTAssertEqual(info.nbnsServers, ["10.1.0.54"])
        XCTAssertEqual(info.vpnAddresses, ["10.20.30.40"])
        XCTAssertEqual(info.vpnNetmasks, ["255.255.255.0"])
        XCTAssertEqual(info.proxyPAC, "https://proxy.example.test/pac")
        XCTAssertEqual(info.mtu, 1390)
        XCTAssertEqual(info.gatewayAddress, "203.0.113.8")
        XCTAssertEqual(info.interfaceName, "utun7")
    }

    func testConnectionDetailsReadOnlyWhitelistedDisplayFields() {
        let details = VPNConnectionDetails(propertyList: [
            "available": true,
            "transport": "DTLS",
            "cstpCipher": "AES-256-GCM",
            "dtlsCipher": "AES256-GCM-SHA384",
            "gatewayHost": "vpn.example.test",
            "gatewayAddress": "203.0.113.8",
            "gatewayPort": 443,
            "rekeySeconds": 3600,
            "rekeyMethod": "new-tunnel",
            "serverMessage": "Authorized access only",
        ])

        XCTAssertTrue(details.isAvailable)
        XCTAssertEqual(details.transport, .dtls)
        XCTAssertEqual(details.cipherDescription, "AES256-GCM-SHA384")
        XCTAssertEqual(details.endpointDescription, "203.0.113.8:443")
        XCTAssertEqual(details.rekeyDescription, "60 мин · new-tunnel")
        XCTAssertEqual(details.serverMessage, "Authorized access only")
    }

    func testTrafficStatsReadUnsignedHelperCounters() {
        let stats = VPNTrafficStats(propertyList: [
            "receivedBytes": NSNumber(value: UInt64(1_048_576)),
            "transmittedBytes": NSNumber(value: UInt64(524_288)),
            "receivedPackets": NSNumber(value: UInt64(120)),
            "transmittedPackets": NSNumber(value: UInt64(80)),
        ])

        XCTAssertTrue(stats.hasTraffic)
        XCTAssertEqual(stats.receivedBytes, 1_048_576)
        XCTAssertEqual(stats.transmittedBytes, 524_288)
        XCTAssertEqual(stats.receivedPackets, 120)
        XCTAssertEqual(stats.transmittedPackets, 80)
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

    @MainActor
    func testAppModelKeepsPollingAfterConnectionAndReportsUnexpectedDisconnect() async throws {
        let tunnel = RecordingTunnelClient()
        let passwordStore = MemoryPasswordStore(password: "secret")
        let service = VPNConnectionService(
            passwordStore: passwordStore,
            attemptGuard: RecordingAttemptGuard(),
            tunnel: tunnel
        )
        let model = AppModel(
            profileStore: MemoryProfileStore(profile: VPNProfile(gateway: "vpn.example.test", group: "staff", username: "max")),
            passwordStore: passwordStore,
            connectionService: service,
            helperInstaller: PrivilegedHelperInstaller(),
            statusPollInterval: .milliseconds(10)
        )

        await model.toggleConnection()
        tunnel.status = TunnelStatus(state: .connected, message: "VPN connected", attemptID: tunnel.attemptID)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(model.status.state, .connected)

        tunnel.status = TunnelStatus(state: .disconnected, message: "VPN-соединение прервано", attemptID: tunnel.attemptID)
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(model.status.state, .disconnected)
        XCTAssertEqual(model.errorMessage, "VPN-соединение прервано")
    }

    @MainActor
    func testSessionExpirationIsShownWithoutAuthenticationFailure() async throws {
        let tunnel = RecordingTunnelClient()
        let passwordStore = MemoryPasswordStore(password: "secret")
        let attemptGuard = RecordingAttemptGuard()
        let notifier = RecordingSessionExpirationNotifier()
        let service = VPNConnectionService(
            passwordStore: passwordStore,
            attemptGuard: attemptGuard,
            tunnel: tunnel
        )
        let model = AppModel(
            profileStore: MemoryProfileStore(profile: VPNProfile(gateway: "vpn.example.test", group: "staff", username: "max")),
            passwordStore: passwordStore,
            connectionService: service,
            helperInstaller: PrivilegedHelperInstaller(),
            sessionExpirationNotifier: notifier,
            statusPollInterval: .milliseconds(10)
        )
        let expiration = Date().addingTimeInterval(3 * 60 * 60)

        await model.toggleConnection()
        tunnel.status = TunnelStatus(
            state: .connected,
            message: "VPN connected",
            attemptID: tunnel.attemptID,
            sessionPolicy: VPNSessionPolicy(expirationDate: expiration)
        )
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(notifier.scheduledExpirations, [expiration])

        tunnel.status = TunnelStatus(
            state: .sessionExpired,
            message: "Срок VPN-сеанса истёк",
            attemptID: tunnel.attemptID,
            sessionPolicy: VPNSessionPolicy(expirationDate: expiration)
        )
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(model.status.state, .sessionExpired)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(attemptGuard.recordedAttemptIDs.isEmpty)
    }

    @MainActor
    func testRefreshGroupsUsesDiscoveryWithoutStartingConnection() async {
        let tunnel = RecordingTunnelClient()
        tunnel.discoveredGroups = [
            VPNGroup(id: "staff", label: "Staff"),
            VPNGroup(id: "admins", label: "Administrators"),
        ]
        let passwordStore = MemoryPasswordStore(password: "secret")
        let model = AppModel(
            profileStore: MemoryProfileStore(profile: VPNProfile(gateway: "vpn.example.test", group: "old", username: "max")),
            passwordStore: passwordStore,
            connectionService: VPNConnectionService(
                passwordStore: passwordStore,
                attemptGuard: RecordingAttemptGuard(),
                tunnel: tunnel
            ),
            helperInstaller: PrivilegedHelperInstaller()
        )

        await model.refreshGroups()

        XCTAssertEqual(tunnel.discoveryCount, 1)
        XCTAssertEqual(tunnel.connectionCount, 0)
        XCTAssertEqual(model.availableGroups, tunnel.discoveredGroups)
        XCTAssertEqual(model.profile.group, "staff")
    }

    @MainActor
    func testAppModelLoadsStoredPasswordForProtectedField() {
        let passwordStore = MemoryPasswordStore(password: "secret")
        let model = AppModel(
            profileStore: MemoryProfileStore(profile: VPNProfile()),
            passwordStore: passwordStore,
            connectionService: VPNConnectionService(
                passwordStore: passwordStore,
                attemptGuard: RecordingAttemptGuard(),
                tunnel: RecordingTunnelClient()
            ),
            helperInstaller: PrivilegedHelperInstaller()
        )

        XCTAssertEqual(model.password, "secret")
        XCTAssertTrue(model.hasStoredPassword)
    }

}

private final class MemoryProfileStore: VPNProfileStore {
    var profile: VPNProfile
    init(profile: VPNProfile) { self.profile = profile }
    func load() -> VPNProfile { profile }
    func save(_ profile: VPNProfile) throws { self.profile = profile }
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
private final class RecordingSessionExpirationNotifier: SessionExpirationNotifying {
    var scheduledExpirations: [Date] = []
    var cancellationCount = 0

    func schedule(expiration: Date) async {
        scheduledExpirations.append(expiration)
    }

    func cancel() {
        cancellationCount += 1
    }
}

@MainActor
private final class RecordingTunnelClient: TunnelClient {
    var status = TunnelStatus(state: .authenticating, message: "Authenticating", attemptID: nil)
    var discoveredGroups = [VPNGroup(id: "staff", label: "Staff")]
    var discoveryCount = 0
    var connectionCount = 0
    var submittedOTPs: [String] = []
    var authenticationFailure = false
    var attemptID: UUID?
    func discoverGroups(gateway: URL) async throws -> [VPNGroup] {
        discoveryCount += 1
        return discoveredGroups
    }
    func connect(request: CiscoAuthenticationRequest) async throws -> TunnelStatus {
        connectionCount += 1
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
