import Foundation

protocol TunnelClient {
    func connect(request: CiscoAuthenticationRequest) async throws -> TunnelStatus
    func disconnect() async throws -> TunnelStatus
}

/// Deliberately refuses to tunnel until a signed privileged transport is added.
/// This prevents an unsafe implementation from leaking secrets in argv or logs.
struct UnavailableTunnelClient: TunnelClient {
    func connect(request: CiscoAuthenticationRequest) async throws -> TunnelStatus {
        _ = request // The request must not be logged or persisted.
        throw VPNError.transportUnavailable
    }

    func disconnect() async throws -> TunnelStatus { .disconnected }
}

