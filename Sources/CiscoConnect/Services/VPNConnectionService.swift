import Foundation

@MainActor
final class VPNConnectionService {
    private let passwordStore: PasswordStore
    private let attemptGuard: AttemptGuard
    private let tunnel: TunnelClient
    private let now: () -> Date
    private var operationID = UUID()

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
        let operation = UUID()
        operationID = operation
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
            let updated = try await tunnel.connect(request: request)
            guard operationID == operation else { throw CancellationError() }
            status = updated
            if status.state == .connected { attemptGuard.resetAfterSuccess() }
        } catch {
            guard operationID == operation else { throw CancellationError() }
            if isAuthenticationFailure(error) {
                _ = attemptGuard.recordAuthenticationFailure(attemptID: attemptID, now: currentTime)
            }
            status = TunnelStatus(state: error is TunnelStartUnconfirmed ? .connecting : .failed, message: error.localizedDescription, attemptID: attemptID)
            throw error
        }
    }

    func disconnect() async throws {
        operationID = UUID()
        status = TunnelStatus(state: .disconnecting, message: "Disconnecting", attemptID: status.attemptID)
        status = try await tunnel.disconnect()
    }

    func submitOTP(_ value: String) async throws {
        guard status.state == .otpRequired else { throw VPNError.otpNotRequested }
        let operation = operationID
        try await tunnel.submitOTP(value)
        guard operationID == operation else { return }
        status = TunnelStatus(state: .authenticating, message: "Checking the one-time code", attemptID: status.attemptID)
    }

    func refreshStatus() async throws -> TunnelStatus {
        let operation = operationID
        do {
            let updated = try await tunnel.currentStatus()
            guard operationID == operation else { return status }
            status = updated
            if updated.state == .connected { attemptGuard.resetAfterSuccess() }
            return updated
        } catch {
            guard operationID == operation else { return status }
            if isAuthenticationFailure(error), let attemptID = status.attemptID {
                _ = attemptGuard.recordAuthenticationFailure(attemptID: attemptID, now: now())
            }
            status = TunnelStatus(state: error is TunnelStartUnconfirmed ? .connecting : .failed, message: error.localizedDescription, attemptID: status.attemptID, progress: (error as? TunnelStartUnconfirmed)?.progress ?? (error as? TunnelDiagnosticFailure)?.progress ?? (error as? AuthenticationFailure)?.progress ?? status.progress)
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
    var progress: VPNConnectionProgress? = nil
    var errorDescription: String? { message }
}

/// The helper may have accepted the request even though its reply was lost.
/// Keep Stop available until the transport confirms disconnection.
struct TunnelStartUnconfirmed: LocalizedError {
    let message: String
    var progress: VPNConnectionProgress? = nil
    var errorDescription: String? { message }
}
