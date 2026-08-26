import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    var profile: VPNProfile
    var password = ""
    var otp = ""
    var status: TunnelStatus = .disconnected
    var errorMessage: String?
    var isSaving = false
    @ObservationIgnored private var statusPollTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPassword = ""

    private let profileStore: VPNProfileStore
    private let passwordStore: PasswordStore
    private let connectionService: VPNConnectionService

    init(
        profileStore: VPNProfileStore,
        passwordStore: PasswordStore,
        connectionService: VPNConnectionService
    ) {
        self.profileStore = profileStore
        self.passwordStore = passwordStore
        self.connectionService = connectionService
        profile = profileStore.load()
        status = connectionService.status
    }

    static func makeLive() -> AppModel {
        let profileStore = UserDefaultsVPNProfileStore()
        let passwordStore = KeychainPasswordStore()
        let attemptGuard = UserDefaultsAttemptGuard()
        let service = VPNConnectionService(
            passwordStore: passwordStore,
            attemptGuard: attemptGuard,
            tunnel: NetworkExtensionTunnelClient()
        )
        return AppModel(
            profileStore: profileStore,
            passwordStore: passwordStore,
            connectionService: service
        )
    }

    var hasStoredPassword: Bool { passwordStore.hasPassword }

    func saveProfile() {
        isSaving = true
        defer { isSaving = false }
        do {
            try profileStore.save(profile)
            if !password.isEmpty {
                try passwordStore.save(password)
                password = ""
            }
            profile = profile.normalized()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleConnection() async {
        errorMessage = nil
        do {
            if status.canDisconnect {
                try await connectionService.disconnect()
            } else {
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

    private func pollTunnelStatus() {
        statusPollTask?.cancel()
        statusPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard let updated = try? await self.connectionService.refreshStatus() else { return }
                self.status = updated
                if updated.state == .connected, !self.pendingPassword.isEmpty {
                    try? self.passwordStore.save(self.pendingPassword)
                    self.password = ""
                    self.pendingPassword = ""
                }
                if !updated.isBusy { return }
            }
        }
    }
}
