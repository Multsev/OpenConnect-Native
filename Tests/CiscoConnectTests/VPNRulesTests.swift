import XCTest
import AppKit
import SwiftUI
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
        let didConnect = await waitUntil { model.status.state == .connected }
        XCTAssertTrue(didConnect)
        XCTAssertEqual(model.status.state, .connected)

        tunnel.status = TunnelStatus(state: .disconnected, message: "VPN-соединение прервано", attemptID: tunnel.attemptID)
        let didDisconnect = await waitUntil { model.status.state == .disconnected }
        XCTAssertTrue(didDisconnect)

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
        let didScheduleExpiration = await waitUntil { notifier.scheduledExpirations == [expiration] }
        XCTAssertTrue(didScheduleExpiration)

        XCTAssertEqual(notifier.scheduledExpirations, [expiration])

        tunnel.status = TunnelStatus(
            state: .sessionExpired,
            message: "Срок VPN-сеанса истёк",
            attemptID: tunnel.attemptID,
            sessionPolicy: VPNSessionPolicy(expirationDate: expiration)
        )
        let didExpire = await waitUntil { model.status.state == .sessionExpired }
        XCTAssertTrue(didExpire)

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

    @MainActor
    func testCancelPendingStartIgnoresLateSuccessAndAllowsReconnect() async {
        let tunnel = RecordingTunnelClient()
        tunnel.suspendConnect = true
        let model = makeCancellationModel(tunnel)
        let start = Task { await model.toggleConnection() }
        let started = await waitUntil { tunnel.connectContinuation != nil }
        XCTAssertTrue(started)
        XCTAssertEqual(model.connectionButtonTitle, "Отменить")
        XCTAssertFalse(model.connectionButtonDisabled)

        await model.toggleConnection()
        XCTAssertEqual(tunnel.disconnectionCount, 1)
        XCTAssertEqual(model.status.state, .disconnected)
        tunnel.connectContinuation?.resume(returning: TunnelStatus(state: .connected, message: "late", attemptID: tunnel.attemptID))
        tunnel.connectContinuation = nil
        await start.value
        XCTAssertEqual(model.status.state, .disconnected)
        XCTAssertNil(model.errorMessage)

        tunnel.suspendConnect = false
        await model.toggleConnection()
        XCTAssertEqual(tunnel.connectionCount, 2)
        XCTAssertEqual(model.status.state, .authenticating)
        await model.disconnect()
    }

    @MainActor
    func testCancellationAvailableDuringOTPAndWithEmptyGateway() async {
        let tunnel = RecordingTunnelClient()
        let model = makeCancellationModel(tunnel)
        await model.toggleConnection()
        model.profile.gateway = ""
        tunnel.status.state = .otpRequired
        let otpShown = await waitUntil { model.status.state == .otpRequired }
        XCTAssertTrue(otpShown)
        XCTAssertFalse(model.connectionButtonDisabled)
        XCTAssertEqual(model.connectionButtonTitle, "Отменить")
        model.otp = "123456"
        await model.toggleConnection()
        XCTAssertEqual(model.otp, "")
        XCTAssertEqual(model.status.state, .disconnected)
    }

    @MainActor
    func testFailedDisconnectCanBeRetried() async {
        let tunnel = RecordingTunnelClient()
        let model = makeCancellationModel(tunnel)
        await model.toggleConnection()
        tunnel.failDisconnect = true
        let stopped = await model.disconnect()
        XCTAssertFalse(stopped)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.connectionButtonDisabled)
        tunnel.failDisconnect = false
        await model.toggleConnection()
        XCTAssertEqual(tunnel.disconnectionCount, 2)
        XCTAssertEqual(model.status.state, .disconnected)
    }

    @MainActor
    func testCancelledGroupDiscoveryDoesNotChangeProfileOrStartVPN() async {
        let tunnel = RecordingTunnelClient()
        tunnel.suspendDiscovery = true
        let model = makeCancellationModel(tunnel)
        model.profile.group = ""
        let start = Task { await model.toggleConnection() }
        let started = await waitUntil { tunnel.discoveryContinuation != nil }
        XCTAssertTrue(started)
        XCTAssertFalse(model.connectionButtonDisabled)
        await model.toggleConnection()
        tunnel.discoveryContinuation?.resume(returning: [VPNGroup(id: "late", label: "Late")])
        tunnel.discoveryContinuation = nil
        await start.value
        XCTAssertEqual(model.profile.group, "")
        XCTAssertTrue(model.availableGroups.isEmpty)
        XCTAssertEqual(tunnel.connectionCount, 0)
        XCTAssertEqual(model.status.state, .disconnected)
    }

    @MainActor
    func testLateStatusReplyCannotReviveCancelledSession() async {
        let tunnel = RecordingTunnelClient()
        tunnel.suspendStatus = true
        let model = makeCancellationModel(tunnel)
        await model.toggleConnection()
        let polling = await waitUntil { tunnel.statusContinuation != nil }
        XCTAssertTrue(polling)
        await model.disconnect()
        tunnel.statusContinuation?.resume(returning: TunnelStatus(state: .connected, message: "late", attemptID: tunnel.attemptID))
        tunnel.statusContinuation = nil
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(model.status.state, .disconnected)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testHelperReplyIgnoresDuplicateCompletion() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let reply = HelperReplyCompletion(continuation: continuation)
            reply.finish(.success(()))
            reply.finish(.failure(VPNError.authenticationTimeout))
        }
    }

    @MainActor
    func testConnectionLayoutFitsOTPAndLongProfileValues() async throws {
        _ = NSApplication.shared
        let model = makeCancellationModel(RecordingTunnelClient())
        model.profile.gateway = "https://" + String(repeating: "long-gateway-", count: 20) + "example.test"
        model.profile.username = String(repeating: "long-user-", count: 30)
        model.profile.group = String(repeating: "long-group-", count: 30)
        model.password = String(repeating: "test-password-", count: 30)
        model.otp = "123456"
        model.availableGroups = [VPNGroup(id: model.profile.group, label: String(repeating: "Very long VPN group ", count: 30))]
        var sizes: [TunnelState: CGSize] = [:]
        for state in [TunnelState.disconnected, .connecting, .otpRequired, .connected, .disconnecting, .failed] {
            model.status = TunnelStatus(state: state, message: "Test", attemptID: nil)
            let host = NSHostingView(rootView: RootView(model: model, menuBarOnly: .constant(true), presentation: .menuBar).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
            host.frame = NSRect(x: 0, y: 0, width: 460, height: 1)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            let size = host.fittingSize
            sizes[state] = size
            XCTAssertEqual(size.width, 460, accuracy: 1, "Width changed for \(state)")
            host.setFrameSize(size)
            host.layoutSubtreeIfNeeded()
            func textFields(in view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
            }
            for field in textFields(in: host) where field.isBezeled {
                XCTAssertGreaterThan(field.frame.width, 200, "Input collapsed for \(state)")
                let frame = field.convert(field.bounds, to: host)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, size.width + 1)
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxY, size.height + 1)
            }
            XCTAssertGreaterThan(size.height, 200)
            XCTAssertLessThan(size.height, 400)
            if let directory = ProcessInfo.processInfo.environment["OPENCONNECT_LAYOUT_SNAPSHOTS"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("layout-\(state.rawValue).png"))
            }
        }
        let normal = try XCTUnwrap(sizes[.connecting])
        let otp = try XCTUnwrap(sizes[.otpRequired])
        XCTAssertGreaterThan(otp.height, normal.height + 20, "OTP must grow the container instead of overflowing it")
    }

    @MainActor
    func testMenuContentReportsHeightWhenOTPIsAddedAndRemoved() async throws {
        let model = makeCancellationModel(RecordingTunnelClient())
        let popover = NSPopover()
        let controller = ContentSizedHostingController(rootView: RootView(
            model: model, menuBarOnly: .constant(true), presentation: .menuBar
        ), onSizeChange: { popover.contentSize = $0 })
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 460, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close() }
        let host = controller.view
        host.frame = NSRect(x: 0, y: 0, width: 460, height: 1)
        func settle() async throws {
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        try await settle()
        let initial = popover.contentSize
        model.status.state = .otpRequired
        try await settle()
        XCTAssertEqual(popover.contentSize.width, 460, accuracy: 1)
        XCTAssertGreaterThan(popover.contentSize.height, initial.height + 20)
        for state in [TunnelState.failed, .disconnected, .connecting, .otpRequired, .sessionExpired, .disconnected] {
            model.status.state = state
            model.isDiscoveringGroups = state == .disconnected
            try await settle()
            XCTAssertEqual(popover.contentSize.width, 460, accuracy: 1)
            if state == .otpRequired {
                XCTAssertGreaterThan(popover.contentSize.height, initial.height + 20)
            } else {
                XCTAssertLessThan(popover.contentSize.height, initial.height + 15)
            }
        }
    }

    @MainActor
    func testLongErrorAndDiagnosticPagesStayWithinTheirViewport() async throws {
        let longText = String(repeating: "Very long diagnostic value without sensitive data. ", count: 500)
        let pages: [(String, AnyView, CGSize)] = [
            ("error", AnyView(VPNErrorView(message: longText, dismiss: {})), CGSize(width: 432, height: 240)),
            ("network", AnyView(NetworkPolicyDetailsView(networkInfo: VPNNetworkInfo(
                isAvailable: true,
                includedRoutes: (0..<200).map { "10.\($0).0.0/16" },
                domains: [longText], proxyPAC: "https://example.test/" + longText
            )).frame(width: 432, height: 202)), CGSize(width: 432, height: 202)),
            ("certificate", AnyView(CertificateDetailsView(details: VPNConnectionDetails(propertyList: [
                "available": true, "gatewayHost": longText, "certificateFingerprint": longText
            ])).frame(width: 432, height: 202)), CGSize(width: 432, height: 202)),
            ("summary", AnyView(ConnectionDetailsView(networkInfo: .empty,
                connectionDetails: VPNConnectionDetails(propertyList: ["available": true, "serverMessage": longText]),
                trafficStats: .empty, sessionPolicy: .empty, isConnected: true, close: {},
                progress: VPNConnectionProgress(propertyList: [
                    "stage": "checkingOTP", "stageStartedAt": Date().timeIntervalSince1970,
                    "events": (0..<20).map { ["stage": "checkingOTP", "time": Date().timeIntervalSince1970 + Double($0)] as [String: Any] }
                ]), progressIsActive: true
            ).frame(width: 432, height: 202)), CGSize(width: 432, height: 202))
        ]
        for (name, page, expected) in pages {
            let host = NSHostingView(rootView: page.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
            host.setFrameSize(expected)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(host.fittingSize.width, expected.width, accuracy: 1, name)
            XCTAssertEqual(host.fittingSize.height, expected.height, accuracy: 1, name)
            if let directory = ProcessInfo.processInfo.environment["OPENCONNECT_LAYOUT_SNAPSHOTS"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("layout-\(name).png"))
            }
        }
    }

    @MainActor
    func testOTPReceivesKeyboardFocusOnEveryNewChallenge() async throws {
        let model = makeCancellationModel(RecordingTunnelClient())
        model.status.state = .connecting
        model.otp = "246810"
        let controller = NSHostingController(rootView: RootView(
            model: model, menuBarOnly: .constant(true), presentation: .menuBar
        ))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 460, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<2 {
            model.status.state = .otpRequired
            let focused = await waitUntil {
                controller.view.layoutSubtreeIfNeeded()
                guard let editor = window.firstResponder as? NSTextView,
                      let field = editor.delegate as? NSTextField else { return false }
                return field.placeholderString == "Код" && editor.string == "246810"
            }
            XCTAssertTrue(focused, "New OTP field should own the keyboard field editor")
            model.status.state = .authenticating
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func testHelperDeathAndStalledOTPProduceStageSpecificErrors() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let progress = try XCTUnwrap(VPNConnectionProgress(propertyList: [
            "stage": "checkingOTP", "stageStartedAt": 1000.0,
            "events": [["stage": "checkingOTP", "time": 1000.0]]
        ]))
        XCTAssertThrowsError(try HelperSessionHealth.check(processAlive: false, progress: progress, startedAt: start, now: start)) {
            XCTAssertTrue($0.localizedDescription.contains("неожиданно завершился"))
            XCTAssertTrue($0.localizedDescription.contains("Проверка OTP"))
            XCTAssertFalse($0 is AuthenticationFailure)
        }
        XCTAssertNoThrow(try HelperSessionHealth.check(processAlive: true, progress: progress, startedAt: start, now: start.addingTimeInterval(44)))
        XCTAssertThrowsError(try HelperSessionHealth.check(processAlive: true, progress: progress, startedAt: start, now: start.addingTimeInterval(51)))
        XCTAssertThrowsError(try HelperSessionHealth.check(processAlive: nil, progress: nil, startedAt: start, now: start.addingTimeInterval(11)))
        let connected = VPNConnectionProgress(propertyList: ["stage": "connected", "stageStartedAt": 1000.0])
        XCTAssertNoThrow(try HelperSessionHealth.check(processAlive: true, progress: connected, startedAt: start, now: start.addingTimeInterval(86400)))
    }

    @MainActor
    func testHelperCrashAfterOTPStopsSpinnerWithoutAuthenticationCooldown() async throws {
        let tunnel = RecordingTunnelClient()
        let guardService = RecordingAttemptGuard()
        let passwords = MemoryPasswordStore(password: "secret")
        let service = VPNConnectionService(passwordStore: passwords, attemptGuard: guardService, tunnel: tunnel)
        let model = AppModel(profileStore: MemoryProfileStore(profile: VPNProfile(gateway: "vpn.example.test", group: "staff", username: "test")), passwordStore: passwords, connectionService: service, helperInstaller: PrivilegedHelperInstaller(), statusPollInterval: .milliseconds(10))
        await model.toggleConnection()
        let progress = VPNConnectionProgress(propertyList: ["stage": "checkingOTP", "stageStartedAt": Date().timeIntervalSince1970])
        tunnel.statusError = TunnelDiagnosticFailure(message: "Системный VPN-компонент неожиданно завершился", progress: progress)
        let failed = await waitUntil { model.status.state == .failed }
        XCTAssertTrue(failed)
        XCTAssertEqual(model.status.progress?.stage, .checkingOTP)
        XCTAssertTrue(model.errorMessage?.contains("Проверка OTP") == true)
        XCTAssertTrue(guardService.recordedAttemptIDs.isEmpty)
        XCTAssertFalse(model.status.isBusy)
    }

    func testProgressRejectsUnknownStagesAndDropsUnapprovedMetadata() throws {
        XCTAssertNil(VPNConnectionProgress(propertyList: ["stage": "raw server text", "stageStartedAt": 1.0]))
        let progress = try XCTUnwrap(VPNConnectionProgress(propertyList: [
            "stage": "checkingOTP", "stageStartedAt": 1.0, "password": "fixture-secret",
            "events": [["stage": "checkingOTP", "time": 1.0, "otp": "fixture-otp"], ["stage": "unknown", "time": 1.0]]
        ]))
        XCTAssertEqual(progress.events.count, 1)
        XCTAssertFalse(String(describing: progress).contains("fixture-secret"))
        XCTAssertFalse(String(describing: progress).contains("fixture-otp"))
    }

    @MainActor
    private func makeCancellationModel(_ tunnel: RecordingTunnelClient) -> AppModel {
        let passwords = MemoryPasswordStore(password: "secret")
        return AppModel(
            profileStore: MemoryProfileStore(profile: VPNProfile(gateway: "vpn.example.test", group: "staff", username: "test")),
            passwordStore: passwords,
            connectionService: VPNConnectionService(passwordStore: passwords, attemptGuard: RecordingAttemptGuard(), tunnel: tunnel),
            helperInstaller: PrivilegedHelperInstaller(),
            statusPollInterval: .milliseconds(10)
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
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
    var statusError: Error?
    var attemptID: UUID?
    var disconnectionCount = 0
    var failDisconnect = false
    var suspendConnect = false
    var suspendDiscovery = false
    var suspendStatus = false
    var connectContinuation: CheckedContinuation<TunnelStatus, Error>?
    var discoveryContinuation: CheckedContinuation<[VPNGroup], Error>?
    var statusContinuation: CheckedContinuation<TunnelStatus, Error>?
    func discoverGroups(gateway: URL) async throws -> [VPNGroup] {
        discoveryCount += 1
        if suspendDiscovery { return try await withCheckedThrowingContinuation { discoveryContinuation = $0 } }
        return discoveredGroups
    }
    func connect(request: CiscoAuthenticationRequest) async throws -> TunnelStatus {
        connectionCount += 1
        attemptID = request.attemptID
        status.attemptID = request.attemptID
        if suspendConnect { return try await withCheckedThrowingContinuation { connectContinuation = $0 } }
        return status
    }
    func submitOTP(_ value: String) async throws { submittedOTPs.append(value) }
    func disconnect() async throws -> TunnelStatus {
        disconnectionCount += 1
        if failDisconnect { throw VPNError.helperFailure("No reply") }
        return .disconnected
    }
    func currentStatus() async throws -> TunnelStatus {
        if suspendStatus { return try await withCheckedThrowingContinuation { statusContinuation = $0 } }
        if let statusError { throw statusError }
        if authenticationFailure { throw AuthenticationFailure(message: "Rejected") }
        return status
    }
}
