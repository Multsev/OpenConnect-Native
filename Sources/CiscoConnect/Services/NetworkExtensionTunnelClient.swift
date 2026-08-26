import Foundation
import NetworkExtension

/// Starts the embedded Packet Tunnel system extension. Secrets are passed only
/// in the transient start options, never in `providerConfiguration`.
@MainActor
final class NetworkExtensionTunnelClient: TunnelClient {
    private let providerBundleIdentifier = "com.max.ciscoconnect.tunnel"
    private var manager: NETunnelProviderManager?

    func connect(request: CiscoAuthenticationRequest) async throws -> TunnelStatus {
        let manager = try await configuredManager(for: request)
        let options: [String: NSObject] = [
            "username": request.username as NSString,
            "password": request.password as NSString,
            "otp": request.otp as NSString,
        ]
        try manager.connection.startVPNTunnel(options: options)
        return TunnelStatus(state: .connecting, message: "Starting Cisco tunnel", attemptID: request.attemptID)
    }

    func disconnect() async throws -> TunnelStatus {
        manager?.connection.stopVPNTunnel()
        return .disconnected
    }

    func currentStatus() async throws -> TunnelStatus {
        let manager = try await activeManager()
        switch manager.connection.status {
        case .connected:
            return TunnelStatus(state: .connected, message: "VPN connected", attemptID: nil)
        case .connecting, .reasserting:
            return TunnelStatus(state: .connecting, message: "Connecting to Cisco gateway", attemptID: nil)
        case .disconnecting:
            return TunnelStatus(state: .disconnecting, message: "Disconnecting", attemptID: nil)
        case .disconnected, .invalid:
            return .disconnected
        @unknown default:
            return TunnelStatus(state: .failed, message: "VPN reported an unknown state", attemptID: nil)
        }
    }

    private func configuredManager(for request: CiscoAuthenticationRequest) async throws -> NETunnelProviderManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = managers.first ?? NETunnelProviderManager()
        let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = providerBundleIdentifier
        configuration.serverAddress = request.gateway.absoluteString
        configuration.providerConfiguration = [
            "gateway": request.gateway.absoluteString,
            "group": request.group,
        ]
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "CiscoConnect"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        self.manager = manager
        return manager
    }

    private func activeManager() async throws -> NETunnelProviderManager {
        if let manager { return manager }
        let manager = try await NETunnelProviderManager.loadAllFromPreferences().first
            ?? NETunnelProviderManager()
        self.manager = manager
        return manager
    }
}
