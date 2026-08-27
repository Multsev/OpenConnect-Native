import Foundation

/// Safe, display-oriented connection metadata copied from libopenconnect.
/// Authentication cookies and raw server headers must never enter this model.
struct VPNConnectionDetails: Equatable, Sendable {
    enum Transport: String, Sendable {
        case tls = "TLS"
        case dtls = "DTLS"
    }

    var isAvailable = false
    var transport: Transport = .tls
    var cstpCipher: String?
    var dtlsCipher: String?
    var cstpCompression: String?
    var dtlsCompression: String?
    var gatewayHost: String?
    var gatewayAddress: String?
    var gatewayPort: Int?
    var certificateFingerprint: String?
    var keepaliveSeconds: Int?
    var dpdSeconds: Int?
    var rekeySeconds: Int?
    var rekeyMethod: String?
    var serverMessage: String?
    var notice: String?

    static let empty = VPNConnectionDetails()

    init(propertyList: [String: Any]? = nil) {
        guard let propertyList else { return }
        isAvailable = propertyList["available"] as? Bool ?? false
        transport = Transport(rawValue: propertyList["transport"] as? String ?? "") ?? .tls
        cstpCipher = Self.text(propertyList["cstpCipher"])
        dtlsCipher = Self.text(propertyList["dtlsCipher"])
        cstpCompression = Self.text(propertyList["cstpCompression"])
        dtlsCompression = Self.text(propertyList["dtlsCompression"])
        gatewayHost = Self.text(propertyList["gatewayHost"])
        gatewayAddress = Self.text(propertyList["gatewayAddress"])
        gatewayPort = Self.positiveInteger(propertyList["gatewayPort"])
        certificateFingerprint = Self.text(propertyList["certificateFingerprint"])
        keepaliveSeconds = Self.positiveInteger(propertyList["keepaliveSeconds"])
        dpdSeconds = Self.positiveInteger(propertyList["dpdSeconds"])
        rekeySeconds = Self.positiveInteger(propertyList["rekeySeconds"])
        rekeyMethod = Self.text(propertyList["rekeyMethod"])
        serverMessage = Self.text(propertyList["serverMessage"])
        notice = Self.text(propertyList["notice"])
    }

    var cipherDescription: String? {
        transport == .dtls ? dtlsCipher ?? cstpCipher : cstpCipher
    }

    var endpointDescription: String? {
        guard let host = gatewayAddress ?? gatewayHost else { return nil }
        guard let gatewayPort else { return host }
        return "\(host):\(gatewayPort)"
    }

    var rekeyDescription: String? {
        guard let rekeySeconds else { return rekeyMethod }
        let minutes = max(1, rekeySeconds / 60)
        if let rekeyMethod { return "\(minutes) мин · \(rekeyMethod)" }
        return "\(minutes) мин"
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func positiveInteger(_ value: Any?) -> Int? {
        let result = (value as? NSNumber)?.intValue
        return result.flatMap { $0 > 0 ? $0 : nil }
    }
}
