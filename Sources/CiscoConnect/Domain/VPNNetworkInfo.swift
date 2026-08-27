import Foundation

/// Network policy received from the VPN gateway for the current connection.
/// It is intentionally kept in memory and is not persisted between launches.
struct VPNNetworkInfo: Equatable, Sendable {
    var isAvailable = false
    var includedRoutes: [String] = []
    var excludedRoutes: [String] = []
    var domains: [String] = []
    var dnsServers: [String] = []
    var nbnsServers: [String] = []
    var vpnAddresses: [String] = []
    var vpnNetmasks: [String] = []
    var proxyPAC: String?
    var mtu: Int?
    var gatewayAddress: String?
    var interfaceName: String?

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
        nbnsServers: [String] = [],
        vpnAddresses: [String] = [],
        vpnNetmasks: [String] = [],
        proxyPAC: String? = nil,
        mtu: Int? = nil,
        gatewayAddress: String? = nil,
        interfaceName: String? = nil
    ) {
        self.isAvailable = isAvailable
        self.includedRoutes = Self.normalized(includedRoutes)
        self.excludedRoutes = Self.normalized(excludedRoutes)
        self.domains = Self.normalized(domains)
        self.dnsServers = Self.normalized(dnsServers)
        self.nbnsServers = Self.normalized(nbnsServers)
        self.vpnAddresses = Self.normalized(vpnAddresses)
        self.vpnNetmasks = Self.normalized(vpnNetmasks)
        self.proxyPAC = Self.normalized(proxyPAC)
        self.mtu = mtu.flatMap { $0 > 0 ? $0 : nil }
        self.gatewayAddress = Self.normalized(gatewayAddress)
        self.interfaceName = Self.normalized(interfaceName)
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
            nbnsServers: propertyList["nbnsServers"] as? [String] ?? [],
            vpnAddresses: propertyList["vpnAddresses"] as? [String] ?? [],
            vpnNetmasks: propertyList["vpnNetmasks"] as? [String] ?? [],
            proxyPAC: propertyList["proxyPAC"] as? String,
            mtu: (propertyList["mtu"] as? NSNumber)?.intValue,
            gatewayAddress: propertyList["gatewayAddress"] as? String,
            interfaceName: propertyList["interfaceName"] as? String
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

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
