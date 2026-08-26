import Foundation

@MainActor
final class VPNConnectionService {
    private let passwordStore: PasswordStore
    private let attemptGuard: AttemptGuard
    private let tunnel: TunnelClient
    private let now: () -> Date

    private(set) var status: TunnelStatus = .disconnected

    init(
        passwordStore: PasswordStore,
        attemptGuard: AttemptGuard,
        tunnel: TunnelClient,
        now: @escaping () -> Date = Date.init
    ) {
        self.passwordStore = passwordStore
        self.attemptGuard = attemptGuard
        self.tunnel = tunnel
        self.now = now
    }

    func discoverGroups(profile: VPNProfile) async throws -> [VPNGroup] {
        let normalized = profile.normalized()
        guard let gateway = URL(string: normalized.gateway), gateway.scheme == "https", gateway.host != nil else { throw VPNError.invalidGateway }
        return try await tunnel.discoverGroups(gateway: gateway)
    }

    func connect(profile: VPNProfile, passwordOverride: String?, otp: String) async throws {
        let currentTime = now()
        if let retryDate = attemptGuard.retryDate(now: currentTime) { throw VPNError.retryBlocked(retryDate) }
        let password = passwordOverride?.isEmpty == false ? passwordOverride! : try passwordStore.read()
        let errors = profile.validationErrors(hasStoredPassword: password?.isEmpty == false)
        if let firstError = errors.first { throw VPNError.invalidProfile(firstError) }
        guard let password, !password.isEmpty else { throw VPNError.invalidProfile("Save the primary VPN password in Keychain.") }

        let attemptID = UUID()
        status = TunnelStatus(state: .connecting, message: "Preparing a secure connection", attemptID: attemptID)
        let request = try CiscoAuthenticationRequest(profile: profile, password: password, otp: otp, attemptID: attemptID)
        do {
            status = TunnelStatus(state: .authenticating, message: "Authenticating with the VPN gateway", attemptID: attemptID)
            status = try await tunnel.connect(request: request)
            if status.state == .connected { attemptGuard.resetAfterSuccess() }
        } catch {
            if isAuthenticationFailure(error) {
                _ = attemptGuard.recordAuthenticationFailure(attemptID: attemptID, now: currentTime)
            }
            status = TunnelStatus(state: .failed, message: error.localizedDescription, attemptID: attemptID)
            throw error
        }
    }

    func disconnect() async throws {
        status = TunnelStatus(state: .disconnecting, message: "Disconnecting", attemptID: status.attemptID)
        status = try await tunnel.disconnect()
    }

    func submitOTP(_ value: String) async throws {
        guard status.state == .otpRequired else { throw VPNError.otpNotRequested }
        try await tunnel.submitOTP(value)
        status = TunnelStatus(state: .authenticating, message: "Checking the one-time code", attemptID: status.attemptID)
    }

    func refreshStatus() async throws -> TunnelStatus {
        do {
            let updated = try await tunnel.currentStatus()
            status = updated
            if updated.state == .connected { attemptGuard.resetAfterSuccess() }
            return updated
        } catch {
            if isAuthenticationFailure(error), let attemptID = status.attemptID {
                _ = attemptGuard.recordAuthenticationFailure(attemptID: attemptID, now: now())
            }
            status = TunnelStatus(state: .failed, message: error.localizedDescription, attemptID: status.attemptID)
            throw error
        }
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        // Real transports must throw an AuthenticationFailure error after a rejected credential form.
        error is AuthenticationFailure
    }
}

struct AuthenticationFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
