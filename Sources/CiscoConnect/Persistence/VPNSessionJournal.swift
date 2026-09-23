import Foundation

/// A bounded local history with a fixed schema; never accepts raw protocol text.
final class VPNSessionJournal {
    struct Event: Codable {
        let time: Date
        let appSession: UUID
        let attempt: UUID?
        let state: String
        let stage: String
        let hasError: Bool
    }
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OpenConnect Native/Automation")
    }
    private let directory: URL?
    private(set) var events: [Event] = []
    private(set) var storageAvailable = true
    private let limit: Int
    private let retention: TimeInterval = 30 * 24 * 3600

    init(directory: URL? = nil, limit: Int = 2000) {
        self.directory = directory
        self.limit = limit
        guard let directory else { return }
        do {
            let file = directory.appendingPathComponent("sessions.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
                guard (size?.intValue ?? 0) <= 2_000_000 else { throw CocoaError(.fileReadTooLarge) }
                events = try JSONDecoder().decode([Event].self, from: Data(contentsOf: file))
            }
            prune(now: Date())
        } catch { storageAvailable = false }
    }

    func append(state: TunnelState, stage: VPNConnectionProgress.Stage?, attempt: UUID?, appSession: UUID, hasError: Bool, now: Date = Date()) {
        events.append(Event(time: now, appSession: appSession, attempt: attempt, state: state.rawValue,
                            stage: stage?.rawValue ?? "", hasError: hasError))
        prune(now: now)
        persist()
    }

    func snapshot(now: Date = Date()) -> [[String: Any]] {
        let oldCount = events.count
        prune(now: now)
        if oldCount != events.count { persist() }
        return events.map {
            ["time": ISO8601DateFormatter().string(from: $0.time), "appSessionID": $0.appSession.uuidString,
             "attemptID": $0.attempt?.uuidString ?? "", "state": $0.state, "stage": $0.stage, "hasError": $0.hasError]
        }
    }

    func sessions() -> [[String: Any]] {
        let grouped = Dictionary(grouping: events.filter { $0.attempt != nil }) {
            "\($0.appSession.uuidString):\($0.attempt!.uuidString)"
        }
        return grouped.values.sorted { $0[0].time < $1[0].time }.suffix(200).map { history in
            let first = history[0]
            let last = history[history.count - 1]
            let connected = history.first { $0.state == "connected" }
            let ended = ["disconnected", "failed", "sessionExpired"].contains(last.state)
            return ["attemptID": first.attempt!.uuidString, "appSessionID": first.appSession.uuidString,
                    "startedAt": ISO8601DateFormatter().string(from: first.time),
                    "connectedAt": connected.map { ISO8601DateFormatter().string(from: $0.time) } as Any? ?? NSNull(),
                    "lastEventAt": ISO8601DateFormatter().string(from: last.time),
                    "lastState": last.state, "endConfirmed": ended,
                    "connectedSeconds": (ended ? connected.map { max(0, Int(last.time.timeIntervalSince($0.time))) } : nil) as Any? ?? NSNull()]
        }
    }

    private func prune(now: Date) {
        events = Array(events.filter { now.timeIntervalSince($0.time) <= retention && $0.time <= now &&
            TunnelState(rawValue: $0.state) != nil && ($0.stage.isEmpty || VPNConnectionProgress.Stage(rawValue: $0.stage) != nil)
        }.suffix(limit))
    }

    private func persist() {
        guard let directory else { return }
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let file = directory.appendingPathComponent("sessions.json")
            try JSONEncoder().encode(events).write(to: file, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            storageAvailable = true
        } catch { storageAvailable = false }
    }
}
