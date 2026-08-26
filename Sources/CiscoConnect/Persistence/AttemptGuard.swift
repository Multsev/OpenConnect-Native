import Foundation

protocol AttemptGuard {
    func retryDate(now: Date) -> Date?
    func recordAuthenticationFailure(attemptID: UUID, now: Date) -> Date
    func resetAfterSuccess()
}

final class UserDefaultsAttemptGuard: AttemptGuard {
    private let failuresKey = "vpn-authentication-failures"
    private let retryKey = "vpn-authentication-retry-date"
    private let lastAttemptKey = "vpn-last-failed-attempt"
    private let defaults: UserDefaults

    private let failureWindow: TimeInterval = 30 * 60
    private let firstCooldown: TimeInterval = 60
    private let repeatedCooldown: TimeInterval = 30 * 60

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func retryDate(now: Date) -> Date? {
        guard let retryDate = defaults.object(forKey: retryKey) as? Date, retryDate > now else { return nil }
        return retryDate
    }

    func recordAuthenticationFailure(attemptID: UUID, now: Date) -> Date {
        if defaults.string(forKey: lastAttemptKey) == attemptID.uuidString {
            return retryDate(now: now) ?? now
        }
        let cutoff = now.addingTimeInterval(-failureWindow)
        var failures = (defaults.array(forKey: failuresKey) as? [Date] ?? []).filter { $0 > cutoff }
        failures.append(now)
        let retry = now.addingTimeInterval(failures.count >= 2 ? repeatedCooldown : firstCooldown)
        defaults.set(failures, forKey: failuresKey)
        defaults.set(retry, forKey: retryKey)
        defaults.set(attemptID.uuidString, forKey: lastAttemptKey)
        return retry
    }

    func resetAfterSuccess() {
        defaults.removeObject(forKey: failuresKey)
        defaults.removeObject(forKey: retryKey)
        defaults.removeObject(forKey: lastAttemptKey)
    }
}

