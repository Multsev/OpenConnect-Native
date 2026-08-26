import Foundation

/// A transport-neutral representation of the Cisco AnyConnect XML form.
/// Secrets remain in memory and must never be serialized or logged.
struct CiscoAuthenticationRequest: Sendable {
    let gateway: URL
    let group: String
    let username: String
    let password: String
    let otp: String
    let attemptID: UUID

    init(profile: VPNProfile, password: String, otp: String, attemptID: UUID) throws {
        let normalized = profile.normalized()
        guard let gateway = URL(string: normalized.gateway) else {
            throw VPNError.invalidGateway
        }
        self.gateway = gateway
        self.group = normalized.group
        self.username = normalized.username
        self.password = password
        self.otp = otp.trimmingCharacters(in: .whitespacesAndNewlines)
        self.attemptID = attemptID
    }

    /// Field identifiers used by ProjectPulse' AnyConnect-compatible XML flow.
    var formEntries: [CiscoFormEntry] {
        var entries = [
            CiscoFormEntry(form: "main", option: "username", value: username),
            CiscoFormEntry(form: "main", option: "password", value: password),
        ]
        if !group.isEmpty {
            entries.append(CiscoFormEntry(form: "main", option: "group_list", value: group))
        }
        if !otp.isEmpty {
            entries.append(CiscoFormEntry(form: "challenge", option: "answer", value: otp))
        }
        return entries
    }
}

struct CiscoFormEntry: Equatable, Sendable {
    let form: String
    let option: String
    let value: String
}

enum VPNError: LocalizedError, Equatable {
    case invalidGateway
    case invalidProfile(String)
    case retryBlocked(Date)
    case transportUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidGateway: "The VPN gateway address is invalid."
        case let .invalidProfile(message): message
        case let .retryBlocked(date): "Authentication is temporarily blocked until \(date.formatted(date: .omitted, time: .shortened))."
        case .transportUnavailable: "No privileged Cisco AnyConnect/OpenConnect tunnel transport is installed."
        }
    }
}

