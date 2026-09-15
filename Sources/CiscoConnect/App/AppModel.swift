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
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
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
        password = (try? passwordStore.read()) ?? ""
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
            if status.canDisconnect || status.isBusy || isDiscoveringGroups {
                guard await disconnect() else { return }
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

    var connectionButtonTitle: String {
        if status.state == .disconnecting { return "Отключение…" }
        if status.state == .connected { return "Отключиться" }
        return status.canDisconnect || isDiscoveringGroups ? "Отменить" : "Подключиться"
    }

    var connectionButtonDisabled: Bool {
        if status.state == .disconnecting { return true }
        if status.canDisconnect || isDiscoveringGroups { return false }
        return profile.normalized().gateway.isEmpty
    }

    func toggleConnection() async {
        guard status.state != .disconnecting else { return }
        if status.canDisconnect || isDiscoveringGroups {
            _ = await disconnect()
            return
        }
        errorMessage = nil
        let id = UUID()
        operationID = id
        status = TunnelStatus(state: .connecting, message: "Подготовка подключения", attemptID: nil)
        let task = Task { await self.startConnection(operation: id) }
        connectionTask = task
        await task.value
        if operationID == id { connectionTask = nil }
    }

    /// Invalidates in-flight UI work before awaiting the transport. A late
    /// connection/poll reply must never revive an attempt the user cancelled.
    @discardableResult
    func disconnect() async -> Bool {
        operationID = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        statusPollTask?.cancel()
        statusPollTask = nil
        isDiscoveringGroups = false
        pendingPassword = ""
        otp = ""
        errorMessage = nil
        cancelSessionNotifications()
        status = TunnelStatus(state: .disconnecting, message: "Отключение", attemptID: status.attemptID)
        do {
            try await connectionService.disconnect()
            status = connectionService.status
            networkInfo = .empty
            connectionDetails = .empty
            trafficStats = .empty
            return true
        } catch {
            // Keep cancellation available if the helper could not confirm it.
            status = TunnelStatus(state: .connecting, message: "Не удалось подтвердить отключение", attemptID: status.attemptID)
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func startConnection(operation id: UUID) async {
        defer { if operationID == id { otp = ""; isDiscoveringGroups = false } }
        do {
            try Task.checkCancellation()
            guard operationID == id else { return }
            cancelSessionNotifications()
            if profile.group.isEmpty, availableGroups.isEmpty {
                isDiscoveringGroups = true
                let groups = try await connectionService.discoverGroups(profile: profile)
                guard operationID == id else { return }
                isDiscoveringGroups = false
                availableGroups = groups
                if let first = groups.first {
                    profile.group = first.id
                    status = TunnelStatus(state: .disconnected, message: "Choose a VPN group, then connect", attemptID: nil)
                    return
                }
            }
            try Task.checkCancellation()
            try profileStore.save(profile)
            let replacementPassword = password
            try await connectionService.connect(
                profile: profile,
                passwordOverride: replacementPassword.isEmpty ? nil : replacementPassword,
                otp: otp
            )
            guard operationID == id else { return }
            pendingPassword = replacementPassword
            status = connectionService.status
            pollTunnelStatus()
        } catch {
            guard operationID == id else { return }
            errorMessage = error.localizedDescription
            status = connectionService.status
        }
    }

    func selectGroup(_ groupID: String) {
        profile.group = groupID
        try? profileStore.save(profile)
    }

    func refreshGroups() async {
        guard !isDiscoveringGroups, !status.canDisconnect, !status.isBusy else { return }
        errorMessage = nil
        isDiscoveringGroups = true
        let id = UUID()
        operationID = id
        let task = Task {
            defer { if self.operationID == id { self.isDiscoveringGroups = false } }
            do {
                try Task.checkCancellation()
                guard self.operationID == id else { return }
                let groups = try await self.connectionService.discoverGroups(profile: self.profile)
                guard self.operationID == id else { return }
                self.availableGroups = groups
                guard !groups.isEmpty else {
                    self.errorMessage = "Шлюз не передал список групп."
                    return
                }
                if !groups.contains(where: { $0.id == self.profile.group }) {
                    self.selectGroup(groups[0].id)
                }
            } catch {
                guard self.operationID == id else { return }
                self.errorMessage = error.localizedDescription
            }
        }
        connectionTask = task
        await task.value
        if operationID == id { connectionTask = nil }
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
        let id = operationID
        statusPollTask?.cancel()
        statusPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.statusPollInterval)
                guard !Task.isCancelled else { return }
                let updated: TunnelStatus
                do { updated = try await self.connectionService.refreshStatus() }
                catch {
                    guard !Task.isCancelled, self.operationID == id else { return }
                    self.status = self.connectionService.status
                    self.errorMessage = error.localizedDescription
                    self.cancelSessionNotifications()
                    return
                }
                guard !Task.isCancelled, self.operationID == id else { return }
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
