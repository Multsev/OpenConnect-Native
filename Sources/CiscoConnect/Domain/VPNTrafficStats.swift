import Foundation

struct VPNTrafficStats: Equatable, Sendable {
    var receivedBytes: UInt64 = 0
    var transmittedBytes: UInt64 = 0
    var receivedPackets: UInt64 = 0
    var transmittedPackets: UInt64 = 0

    private(set) var isAvailable = false

    static let empty = VPNTrafficStats()

    init(propertyList: [String: Any]? = nil) {
        guard let propertyList else { return }
        isAvailable = propertyList["receivedBytes"] is NSNumber && propertyList["transmittedBytes"] is NSNumber
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

struct TrafficRate: Equatable, Identifiable {
    let id: TimeInterval
    let received: Double
    let transmitted: Double
}

struct TrafficHistory {
    private var previous: (stats: VPNTrafficStats, time: TimeInterval)?
    private(set) var latest: TrafficRate?
    private(set) var inboundOffset: Double = 0
    private(set) var outboundOffset: Double = 0

    mutating func record(_ stats: VPNTrafficStats, at time: TimeInterval) {
        guard stats.isAvailable else {
            self = TrafficHistory()
            return
        }
        defer { previous = (stats, time) }
        guard let previous else { return }
        let elapsed = time - previous.time
        guard elapsed > 0, elapsed < 5,
              stats.receivedBytes >= previous.stats.receivedBytes,
              stats.transmittedBytes >= previous.stats.transmittedBytes else {
            inboundOffset = 0
            outboundOffset = 0
            latest = nil
            return
        }
        if let latest {
            inboundOffset += elapsed * TrafficLane(bytesPerSecond: latest.received).speed
            outboundOffset += elapsed * TrafficLane(bytesPerSecond: latest.transmitted).speed
        }
        latest = TrafficRate(id: time,
            received: Double(stats.receivedBytes - previous.stats.receivedBytes) / elapsed,
            transmitted: Double(stats.transmittedBytes - previous.stats.transmittedBytes) / elapsed)
    }
}

/// A fixed visual scale for throughput. VPN peers do not advertise channel capacity.
struct TrafficLane {
    let count: Int
    let speed: Double

    init(bytesPerSecond: Double) {
        guard bytesPerSecond > 0 else {
            count = 0
            speed = 0
            return
        }
        let density = min(log1p(bytesPerSecond / 4096) / log1p(1024), 1)
        count = max(1, Int(ceil(16 * density)))
        speed = 4 + 72 * pow(1 - density, 1.6)
    }
}
