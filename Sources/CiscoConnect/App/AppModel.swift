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
    var errorMessage: String?
    @ObservationIgnored private var statusPollTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPassword = ""
    @ObservationIgnored private let statusPollInterval: Duration

    private let profileStore: VPNProfileStore
    private let passwordStore: PasswordStore
    private let connectionService: VPNConnectionService
    private let helperInstaller: PrivilegedHelperInstaller

    init(
        profileStore: VPNProfileStore,
        passwordStore: PasswordStore,
        connectionService: VPNConnectionService,
        helperInstaller: PrivilegedHelperInstaller,
        statusPollInterval: Duration = .seconds(1)
    ) {
        self.profileStore = profileStore
        self.passwordStore = passwordStore
        self.connectionService = connectionService
        self.helperInstaller = helperInstaller
        self.statusPollInterval = statusPollInterval
        profile = profileStore.load()
        status = connectionService.status
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
            helperInstaller: helperInstaller
        )
    }

    var hasStoredPassword: Bool { passwordStore.hasPassword }
    var isSystemHelperInstalled: Bool { helperInstaller.isInstalled }

    func uninstallSystemHelper() async {
        errorMessage = nil
        do {
            statusPollTask?.cancel()
            if status.canDisconnect {
                try await connectionService.disconnect()
            }
            try await helperInstaller.uninstall()
            status = .disconnected
            networkInfo = .empty
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
            } else {
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
                    return
                }
                self.status = updated
                if updated.networkInfo.isAvailable {
                    self.networkInfo = updated.networkInfo
                }
                if updated.state == .connected, !self.pendingPassword.isEmpty {
                    try? self.passwordStore.save(self.pendingPassword)
                    self.password = ""
                    self.pendingPassword = ""
                }
                switch updated.state {
                case .connecting, .authenticating, .otpRequired, .connected:
                    continue
                case .disconnected:
                    if updated.message != TunnelStatus.disconnected.message,
                       updated.message != "VPN отключён пользователем" {
                        self.errorMessage = updated.message
                    }
                    return
                case .disconnecting, .failed:
                    return
                }
            }
        }
    }
}
