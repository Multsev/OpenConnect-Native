import Foundation

struct VPNTrafficStats: Equatable, Sendable {
    var receivedBytes: UInt64 = 0
    var transmittedBytes: UInt64 = 0
    var receivedPackets: UInt64 = 0
    var transmittedPackets: UInt64 = 0

    static let empty = VPNTrafficStats()

    init(propertyList: [String: Any]? = nil) {
        guard let propertyList else { return }
        receivedBytes = Self.unsigned(propertyList["receivedBytes"])
        transmittedBytes = Self.unsigned(propertyList["transmittedBytes"])
        receivedPackets = Self.unsigned(propertyList["receivedPackets"])
        transmittedPackets = Self.unsigned(propertyList["transmittedPackets"])
    }

    var hasTraffic: Bool { receivedBytes > 0 || transmittedBytes > 0 }

    var receivedDescription: String { Self.byteCountFormatter.string(fromByteCount: Int64(clamping: receivedBytes)) }
    var transmittedDescription: String { Self.byteCountFormatter.string(fromByteCount: Int64(clamping: transmittedBytes)) }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    private static func unsigned(_ value: Any?) -> UInt64 {
        (value as? NSNumber)?.uint64Value ?? 0
    }
}
