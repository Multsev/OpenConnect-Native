import Foundation

/// A rolling budget survives successful short connections and app restarts,
/// so an unstable gateway cannot cause an unlimited authentication loop.
struct AutomaticReconnectPolicy {
    static let maximumAttempts = 3
    static let window: TimeInterval = 30 * 60
    static let delays: [TimeInterval] = [15, 60, 180]
    private(set) var attempts: [Date]

    init(attempts: [Date] = []) { self.attempts = attempts }

    mutating func reserve(now: Date) -> (number: Int, delay: TimeInterval)? {
        attempts = attempts.filter { $0 > now.addingTimeInterval(-Self.window) }
        guard attempts.count < Self.maximumAttempts else { return nil }
        let delay = Self.delays[attempts.count]
        attempts.append(now)
        return (attempts.count, delay)
    }
}
