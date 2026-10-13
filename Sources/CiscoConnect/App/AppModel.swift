import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    var automaticReconnectEnabled: Bool {
        didSet {
            reconnectDefaults.set(automaticReconnectEnabled, forKey: "vpn-automatic-reconnect")
            if !automaticReconnectEnabled { cancelAutomaticReconnect() }
        }
    }
    private(set) var reconnectMessage: String?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectArmed = false
    @ObservationIgnored private var automaticAttempt = false
    @ObservationIgnored private var otpWasRequested = false
    @ObservationIgnored private var reconnectPolicy: AutomaticReconnectPolicy
    @ObservationIgnored private let reconnectDelayScale: Double
    @ObservationIgnored private let reconnectDefaults: UserDefaults
    @ObservationIgnored var onOTPRequired: (() -> Void)?
    var profile: VPNProfile
    var password = ""
    var otp = ""
    var availableGroups: [VPNGroup] = []
    var isDiscoveringGroups = false
    var status: TunnelStatus = .disconnected { didSet { onConnectionStateChange?() } }
    var networkInfo: VPNNetworkInfo = .empty
    var connectionDetails: VPNConnectionDetails = .empty
    var trafficStats: VPNTrafficStats = .empty
    private(set) var hasStoredPassword = false
    private(set) var isLoadingSavedPassword = false
    var errorMessage: String? { didSet { onConnectionStateChange?() } }
    @ObservationIgnored var onConnectionStateChange: (() -> Void)?
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
        statusPollInterval: Duration = .seconds(1),
        loadPasswordOnLaunch: Bool = true,
        reconnectDefaults: UserDefaults = .standard,
        reconnectDelayScale: Double = 1
    ) {
        self.reconnectDelayScale = reconnectDelayScale
        self.reconnectDefaults = reconnectDefaults
        self.automaticReconnectEnabled = reconnectDefaults.bool(forKey: "vpn-automatic-reconnect")
        self.reconnectPolicy = AutomaticReconnectPolicy(attempts: reconnectDefaults.array(forKey: "vpn-reconnect-attempts") as? [Date] ?? [])
        self.profileStore = profileStore
        self.passwordStore = passwordStore
        self.connectionService = connectionService
        self.helperInstaller = helperInstaller
        self.sessionExpirationNotifier = sessionExpirationNotifier ?? NoopSessionExpirationNotifier()
        self.statusPollInterval = statusPollInterval
        profile = profileStore.load()
        if loadPasswordOnLaunch {
            password = (try? passwordStore.read()) ?? ""
            hasStoredPassword = !password.isEmpty
        }
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
        let model = AppModel(
            profileStore: profileStore,
            passwordStore: passwordStore,
            connectionService: service,
            helperInstaller: helperInstaller,
            sessionExpirationNotifier: UserNotificationSessionExpirationNotifier(),
            loadPasswordOnLaunch: false
        )
        model.isLoadingSavedPassword = true
        Task { await model.loadSavedPassword() }
        return model
    }

    private func loadSavedPassword() async {
        defer { isLoadingSavedPassword = false }
        let saved = (try? await PasswordStoreWorker.read(passwordStore)) ?? ""
        hasStoredPassword = !saved.isEmpty
        // Do not replace edits made while Keychain was responding.
        if password.isEmpty { password = saved }
    }
    var hasConfiguredProfile: Bool {
        profile.validationErrors(hasStoredPassword: hasStoredPassword || !password.isEmpty).isEmpty
    }

    func saveProfileSettings() -> Bool {
        guard hasConfiguredProfile else {
            errorMessage = "Заполните шлюз, логин и пароль в настройках подключения"
            return false
        }
        do {
            try profileStore.save(profile)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

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
        if reconnectTask != nil { return "Отменить переподключение" }
        if status.state == .disconnecting { return "Отключение…" }
        if status.state == .connected { return "Отключиться" }
        return status.canDisconnect || isDiscoveringGroups ? "Отменить" : "Подключиться"
    }

    var connectionButtonDisabled: Bool {
        if status.state == .disconnecting { return true }
        if status.canDisconnect || isDiscoveringGroups { return false }
        return profile.normalized().gateway.isEmpty
    }

    /// Changes visible state in the click handler before scheduling VPN work.
    func connectionButtonPressed() {
        if reconnectTask != nil { cancelAutomaticReconnect(); return }
        let started = PerformanceMeasurements.start()
        guard status.state != .disconnecting else { return }
        if status.canDisconnect || isDiscoveringGroups {
            status = TunnelStatus(state: .disconnecting, message: "Отключение", attemptID: status.attemptID)
            Task { _ = await disconnect() }
        } else {
            _ = beginConnection()
        }
        PerformanceMeasurements.shared.record(.buttonFeedback, since: started)
    }

    func toggleConnection() async {
        if reconnectTask != nil { cancelAutomaticReconnect(); return }
        guard status.state != .disconnecting else { return }
        if status.canDisconnect || isDiscoveringGroups {
            _ = await disconnect()
        } else {
            await beginConnection().value
        }
    }

    private func beginConnection(automatic: Bool = false) -> Task<Void, Never> {
        if !automatic { cancelAutomaticReconnect(); reconnectMessage = nil }
        automaticAttempt = automatic
        otpWasRequested = false
        errorMessage = nil
        let id = UUID()
        operationID = id
        status = TunnelStatus(state: .connecting, message: "Подготовка подключения", attemptID: nil)
        let task = Task {
            await self.startConnection(operation: id)
            if self.operationID == id { self.connectionTask = nil }
        }
        connectionTask = task
        return task
    }

    /// Invalidates in-flight UI work before awaiting the transport. A late
    /// connection/poll reply must never revive an attempt the user cancelled.
    @discardableResult
    func disconnect() async -> Bool {
        cancelAutomaticReconnect()
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
            handleConnectionEnd(error: error)
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
                let interval = self.status.state == .connected ? self.statusPollInterval : min(self.statusPollInterval, .milliseconds(250))
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                let updated: TunnelStatus
                do { updated = try await self.connectionService.refreshStatus() }
                catch {
                    guard !Task.isCancelled, self.operationID == id else { return }
                    self.status = self.connectionService.status
                    self.errorMessage = error.localizedDescription
                    self.cancelSessionNotifications()
                    self.handleConnectionEnd(error: error)
                    return
                }
                guard !Task.isCancelled, self.operationID == id else { return }
                let previousState = self.status.state
                self.status = updated
                if updated.state == .otpRequired && previousState != .otpRequired {
                    self.otpWasRequested = true
                    self.onOTPRequired?()
                }
                if updated.state == .connected {
                    self.reconnectArmed = true
                    self.automaticAttempt = false
                    self.otpWasRequested = false
                    self.reconnectMessage = nil
                }
                if updated.networkInfo.isAvailable {
                    self.networkInfo = updated.networkInfo
                }
                if updated.connectionDetails.isAvailable {
                    self.connectionDetails = updated.connectionDetails
                }
                self.trafficStats = updated.trafficStats
                if updated.state == .connected, !self.pendingPassword.isEmpty {
                    let passwordToSave = self.pendingPassword
                    do {
                        try await PasswordStoreWorker.save(passwordToSave, to: self.passwordStore)
                        self.hasStoredPassword = true
                    } catch {
                        self.errorMessage = error.localizedDescription
                    }
                    guard !Task.isCancelled, self.operationID == id else { return }
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
                        self.handleConnectionEnd()
                    }
                    return
                case .sessionExpired:
                    self.handleConnectionEnd()
                    return
                case .disconnecting, .failed:
                    self.cancelSessionNotifications()
                    if updated.state == .failed { self.handleConnectionEnd() }
                    return
                }
            }
        }
    }

    private func cancelAutomaticReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectArmed = false
        automaticAttempt = false
        reconnectMessage = nil
    }

    private func handleConnectionEnd(error: Error? = nil) {
        guard automaticReconnectEnabled, reconnectArmed || automaticAttempt, reconnectTask == nil else { return }
        let reason = error?.localizedDescription ?? status.message
        let lower = reason.lowercased()
        let unsafeToRetry = otpWasRequested || error is AuthenticationFailure || status.state == .otpRequired ||
            status.progress?.stage == .waitingOTP || status.progress?.stage == .checkingOTP ||
            ["reject", "blocked", "ban", "lock", "credential", "one-time", "otp", "отказ", "блокир"].contains(where: lower.contains)
        if unsafeToRetry {
            reconnectArmed = false
            automaticAttempt = false
            reconnectMessage = "Автопереподключение остановлено. Попыток за 30 мин: \(reconnectPolicy.attempts.count). Причина: \(reason)"
            return
        }
        guard let attempt = reconnectPolicy.reserve(now: Date()) else {
            reconnectArmed = false
            automaticAttempt = false
            reconnectMessage = "Переподключение не удалось: лимит 3 попытки за 30 минут исчерпан. Причина: \(reason)"
            return
        }
        reconnectDefaults.set(reconnectPolicy.attempts, forKey: "vpn-reconnect-attempts")
        reconnectMessage = "Переподключение: попытка \(attempt.number) из 3 через \(Int(attempt.delay)) с. Причина: \(reason)"
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(attempt.delay * (self?.reconnectDelayScale ?? 1))) } catch { return }
            guard let self, !Task.isCancelled, self.automaticReconnectEnabled else { return }
            // Confirm the old helper has stopped before creating a fresh auth context.
            do { try await self.connectionService.disconnect() } catch {
                self.reconnectTask = nil
                self.reconnectArmed = false
                self.reconnectMessage = "Переподключение остановлено: не удалось подтвердить завершение предыдущего сеанса. \(error.localizedDescription)"
                return
            }
            guard !Task.isCancelled, self.automaticReconnectEnabled else { return }
            self.reconnectTask = nil
            self.reconnectMessage = "Переподключение: попытка \(attempt.number) из 3"
            await self.beginConnection(automatic: true).value
        }
    }

    private func cancelSessionNotifications() {
        scheduledExpiration = nil
        sessionExpirationNotifier.cancel()
    }
}
