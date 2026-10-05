import Foundation

/// Bounded, in-memory timings. Only fixed operation names and durations are kept.
final class PerformanceMeasurements: @unchecked Sendable {
    enum Operation: String {
        case panelColdOpen, panelWarmOpen, buttonFeedback, keychainRead
        case helperReady, requestPreparation, helperStart, helperStop
    }

    static let shared = PerformanceMeasurements()
    private let lock = NSLock()
    private var samples: [(Operation, Double)] = []

    static func start() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func record(_ operation: Operation, since start: UInt64) {
        let end = Self.start()
        let milliseconds = Double(end >= start ? end - start : 0) / 1_000_000
        lock.lock()
        defer { lock.unlock() }
        samples.append((operation, milliseconds))
        if samples.count > 64 { samples.removeFirst(samples.count - 64) }
    }

    func snapshot() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return samples.map { ["operation": $0.0.rawValue, "milliseconds": $0.1] }
    }
}
