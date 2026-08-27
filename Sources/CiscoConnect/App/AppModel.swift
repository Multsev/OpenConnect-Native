import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    var profile: VPNProfile
    var password = ""
    var otp = ""
    var availableGroups: [VPNGroup] = []
    var isDiscoveringGroups = false
    var status: TunnelStatus = .disconnected
    var networkInfo: VPNNetworkInfo = .empty
    var connectionDetails: VPNConnectionDetails = .empty
    var trafficStats: VPNTrafficStats = .empty
    var errorMessage: String?
    @ObservationIgnored private var statusPollTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPassword = ""
    @ObservationIgnored private var scheduledExpiration: Date?
    @ObservationIgnored private let statusPollInterval: Duration

    private let profileStore: VPNProfileStore
    private let passwordStore: PasswordStore
    private let connectionService: VPNConnectionService
    private let helperInstaller: PrivilegedHelperInstaller
    private let sessionExpirationNotifier: SessionExpirationNotifying

    init(
        profileStore: VPNProfileStore,
        passwordStore: PasswordStore,
        connectionService: VPNConnectionService,
        helperInstaller: PrivilegedHelperInstaller,
        sessionExpirationNotifier: SessionExpirationNotifying? = nil,
        statusPollInterval: Duration = .seconds(1)
    ) {
        self.profileStore = profileStore
        self.passwordStore = passwordStore
        self.connectionService = connectionService
        self.helperInstaller = helperInstaller
        self.sessionExpirationNotifier = sessionExpirationNotifier ?? NoopSessionExpirationNotifier()
        self.statusPollInterval = statusPollInterval
        profile = profileStore.load()
        status = connectionService.status
        self.sessionExpirationNotifier.cancel()
    }

    static func makeLive() -> AppModel {
        let profileStore = UserDefaultsVPNProfileStore()
        let passwordStore = KeychainPasswordStore()
        let attemptGuard = UserDefaultsAttemptGuard()
        let helperConnection = PrivilegedHelperConnection()
        let helperInstaller = PrivilegedHelperInstaller()
        let service = VPNConnectionService(
            passwordStore: passwordStore,
            attemptGuard: attemptGuard,
            tunnel: OpenConnectProcessTunnelClient(
                helperConnection: helperConnection,
                helperInstaller: helperInstaller
            )
        )
        return AppModel(
            profileStore: profileStore,
            passwordStore: passwordStore,
            connectionService: service,
            helperInstaller: helperInstaller,
            sessionExpirationNotifier: UserNotificationSessionExpirationNotifier()
        )
    }

    var hasStoredPassword: Bool { passwordStore.hasPassword }
    var isSystemHelperInstalled: Bool { helperInstaller.isInstalled }

    func uninstallSystemHelper() async {
        errorMessage = nil
        do {
            statusPollTask?.cancel()
            cancelSessionNotifications()
            if status.canDisconnect {
                try await connectionService.disconnect()
            }
            try await helperInstaller.uninstall()
            status = .disconnected
            networkInfo = .empty
            connectionDetails = .empty
            trafficStats = .empty
        } catch {
            errorMessage = error.localizedDescription
            status = connectionService.status
        }
    }

    func toggleConnection() async {
        errorMessage = nil
        do {
            if status.canDisconnect {
                try await connectionService.disconnect()
                cancelSessionNotifications()
            } else {
                cancelSessionNotifications()
                if profile.group.isEmpty, availableGroups.isEmpty {
                    isDiscoveringGroups = true
                    defer { isDiscoveringGroups = false }
                    availableGroups = try await connectionService.discoverGroups(profile: profile)
                    if let first = availableGroups.first {
                        profile.group = first.id
                        status = TunnelStatus(state: .disconnected, message: "Choose a VPN group, then connect", attemptID: nil)
                        return
                    }
                }
                try profileStore.save(profile)
                let replacementPassword = password
                // OTP is intentionally scoped to one attempt, including failures.
                defer { otp = "" }
                try await connectionService.connect(
                    profile: profile,
                    passwordOverride: replacementPassword.isEmpty ? nil : replacementPassword,
                    otp: otp
                )
                pendingPassword = replacementPassword
                status = connectionService.status
                pollTunnelStatus()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        status = connectionService.status
    }

    func selectGroup(_ groupID: String) {
        profile.group = groupID
        try? profileStore.save(profile)
    }

    func refreshGroups() async {
        guard !isDiscoveringGroups, !status.canDisconnect else { return }
        errorMessage = nil
        isDiscoveringGroups = true
        defer { isDiscoveringGroups = false }

        do {
            let groups = try await connectionService.discoverGroups(profile: profile)
            availableGroups = groups
            guard !groups.isEmpty else {
                errorMessage = "Шлюз не передал список групп."
                return
            }
            if !groups.contains(where: { $0.id == profile.group }) {
                selectGroup(groups[0].id)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submitOTP() async {
        let value = otp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        otp = ""
        do {
            try await connectionService.submitOTP(value)
            status = connectionService.status
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pollTunnelStatus() {
        statusPollTask?.cancel()
        statusPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.statusPollInterval)
                guard !Task.isCancelled else { return }
                let updated: TunnelStatus
                do { updated = try await self.connectionService.refreshStatus() }
                catch {
                    self.status = self.connectionService.status
                    self.errorMessage = error.localizedDescription
                    self.cancelSessionNotifications()
                    return
                }
                self.status = updated
                if updated.networkInfo.isAvailable {
                    self.networkInfo = updated.networkInfo
                }
                if updated.connectionDetails.isAvailable {
                    self.connectionDetails = updated.connectionDetails
                }
                self.trafficStats = updated.trafficStats
                if updated.state == .connected, !self.pendingPassword.isEmpty {
                    try? self.passwordStore.save(self.pendingPassword)
                    self.password = ""
                    self.pendingPassword = ""
                }
                if updated.state == .connected,
                   let expiration = updated.sessionPolicy.expirationDate,
                   expiration != self.scheduledExpiration {
                    self.scheduledExpiration = expiration
                    await self.sessionExpirationNotifier.schedule(expiration: expiration)
                }
                switch updated.state {
                case .connecting, .authenticating, .otpRequired, .connected:
                    continue
                case .disconnected:
                    self.cancelSessionNotifications()
                    if updated.message != TunnelStatus.disconnected.message,
                       updated.message != "VPN отключён пользователем" {
                        self.errorMessage = updated.message
                    }
                    return
                case .sessionExpired:
                    return
                case .disconnecting, .failed:
                    self.cancelSessionNotifications()
                    return
                }
            }
        }
    }

    private func cancelSessionNotifications() {
        scheduledExpiration = nil
        sessionExpirationNotifier.cancel()
    }
}
