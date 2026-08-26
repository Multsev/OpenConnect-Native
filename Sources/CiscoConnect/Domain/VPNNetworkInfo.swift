import Foundation

/// Network policy received from the VPN gateway for the current connection.
/// It is intentionally kept in memory and is not persisted between launches.
struct VPNNetworkInfo: Equatable, Sendable {
    var isAvailable = false
    var includedRoutes: [String] = []
    var excludedRoutes: [String] = []
    var domains: [String] = []
    var dnsServers: [String] = []
    var vpnAddresses: [String] = []

    static let empty = VPNNetworkInfo()

    var usesSplitTunnel: Bool {
        isAvailable && !includedRoutes.isEmpty
    }

    init(
        isAvailable: Bool = false,
        includedRoutes: [String] = [],
        excludedRoutes: [String] = [],
        domains: [String] = [],
        dnsServers: [String] = [],
        vpnAddresses: [String] = []
    ) {
        self.isAvailable = isAvailable
        self.includedRoutes = Self.normalized(includedRoutes)
        self.excludedRoutes = Self.normalized(excludedRoutes)
        self.domains = Self.normalized(domains)
        self.dnsServers = Self.normalized(dnsServers)
        self.vpnAddresses = Self.normalized(vpnAddresses)
    }

    init(propertyList: [String: Any]?) {
        guard let propertyList else {
            self = .empty
            return
        }
        self.init(
            isAvailable: propertyList["available"] as? Bool ?? false,
            includedRoutes: propertyList["includedRoutes"] as? [String] ?? [],
            excludedRoutes: propertyList["excludedRoutes"] as? [String] ?? [],
            domains: propertyList["domains"] as? [String] ?? [],
            dnsServers: propertyList["dnsServers"] as? [String] ?? [],
            vpnAddresses: propertyList["vpnAddresses"] as? [String] ?? []
        )
    }

    private static func normalized(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }
}
