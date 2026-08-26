import Foundation

protocol TunnelClient {
    func discoverGroups(gateway: URL) async throws -> [VPNGroup]
    func connect(request: CiscoAuthenticationRequest) async throws -> TunnelStatus
    func submitOTP(_ value: String) async throws
    func disconnect() async throws -> TunnelStatus
    func currentStatus() async throws -> TunnelStatus
}

/// Deliberately refuses to tunnel until a signed privileged transport is added.
/// This prevents an unsafe implementation from leaking secrets in argv or logs.
struct UnavailableTunnelClient: TunnelClient {
    func discoverGroups(gateway: URL) async throws -> [VPNGroup] { throw VPNError.transportUnavailable }
    func connect(request: CiscoAuthenticationRequest) async throws -> TunnelStatus {
        _ = request // The request must not be logged or persisted.
        throw VPNError.transportUnavailable
    }

    func submitOTP(_ value: String) async throws { throw VPNError.transportUnavailable }

    func disconnect() async throws -> TunnelStatus { .disconnected }

    func currentStatus() async throws -> TunnelStatus { .disconnected }
}

struct VPNGroup: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
}
