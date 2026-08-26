import Foundation

struct VPNProfile: Codable, Equatable, Sendable {
    var gateway: String = ""
    var group: String = ""
    var username: String = ""

    func normalized() -> VPNProfile {
        VPNProfile(
            gateway: Self.normalizeGateway(gateway),
            group: group.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func validationErrors(hasStoredPassword: Bool) -> [String] {
        let value = normalized()
        var errors: [String] = []
        guard let url = URL(string: value.gateway), url.scheme == "https", url.host != nil else {
            return ["Enter an HTTPS address for the VPN gateway."]
        }
        if value.username.isEmpty { errors.append("Enter a VPN username.") }
        if !hasStoredPassword { errors.append("Save the primary VPN password in Keychain.") }
        return errors
    }

    static func normalizeGateway(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: withScheme), components.host != nil else {
            return withScheme
        }
        if components.path == "/" { components.path = "" }
        return components.string ?? withScheme
    }
}

enum TunnelState: String, Sendable {
    case disconnected, connecting, authenticating, otpRequired, connected, disconnecting, failed

    var isBusy: Bool {
        self == .connecting || self == .authenticating || self == .otpRequired || self == .disconnecting
    }

    var canDisconnect: Bool {
        self == .connecting || self == .authenticating || self == .otpRequired || self == .connected
    }
}

struct TunnelStatus: Equatable, Sendable {
    var state: TunnelState
    var message: String
    var attemptID: UUID?
    var networkInfo: VPNNetworkInfo = .empty

    static let disconnected = TunnelStatus(state: .disconnected, message: "VPN disconnected", attemptID: nil)

    var isBusy: Bool { state.isBusy }
    var canDisconnect: Bool { state.canDisconnect }
}
