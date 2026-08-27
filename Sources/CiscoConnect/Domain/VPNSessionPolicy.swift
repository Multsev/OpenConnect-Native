import Foundation

/// Server-provided limits for the current authenticated VPN session.
/// These values stay in memory and are never persisted between launches.
struct VPNSessionPolicy: Equatable, Sendable {
    var expirationDate: Date?
    var idleTimeout: TimeInterval?

    static let empty = VPNSessionPolicy()

    init(expirationDate: Date? = nil, idleTimeout: TimeInterval? = nil) {
        self.expirationDate = expirationDate
        self.idleTimeout = idleTimeout.flatMap { $0 > 0 ? $0 : nil }
    }

    init(expirationTimestamp: TimeInterval?, idleTimeout: TimeInterval?) {
        let expirationDate = expirationTimestamp.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        self.init(expirationDate: expirationDate, idleTimeout: idleTimeout)
    }

    var isAvailable: Bool {
        expirationDate != nil || idleTimeout != nil
    }

    func remainingTime(at date: Date) -> TimeInterval? {
        expirationDate.map { max(0, $0.timeIntervalSince(date)) }
    }

    func hasExpired(at date: Date) -> Bool {
        expirationDate.map { $0 <= date } ?? false
    }

    func remainingDescription(at date: Date) -> String? {
        guard let remainingTime = remainingTime(at: date) else { return nil }
        let totalMinutes = Int(remainingTime) / 60
        if totalMinutes >= 60 {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            return minutes == 0 ? "\(hours) ч" : "\(hours) ч \(minutes) мин"
        }
        if totalMinutes > 0 { return "\(totalMinutes) мин" }
        return "< 1 мин"
    }

    func isExpiringSoon(at date: Date, warningInterval: TimeInterval = 15 * 60) -> Bool {
        guard let remainingTime = remainingTime(at: date) else { return false }
        return remainingTime > 0 && remainingTime <= warningInterval
    }

    var idleTimeoutDescription: String? {
        guard let idleTimeout else { return nil }
        let totalMinutes = Int(idleTimeout) / 60
        if totalMinutes >= 60 {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            return minutes == 0 ? "\(hours) ч" : "\(hours) ч \(minutes) мин"
        }
        return totalMinutes > 0 ? "\(totalMinutes) мин" : "< 1 мин"
    }
}
