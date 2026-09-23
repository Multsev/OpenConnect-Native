import Foundation

/// Commands share AppModel's authentication, cancellation and cooldown rules.
@MainActor
final class AutomationController {
    private let model: AppModel
    private let server = LocalControlServer()
    private var timer: Timer?
    private var commandGeneration = UUID()
    private var connecting = false
    private var stopping = false
    private var submittingOTP = false
    private var events: [[String: Any]] = []
    private var lastEvent = ""
    private var submittedChallenge: String?
    private let appSession = UUID()
    private var lastAttempt: UUID?
    private var connectedAt: Date?
    private var journal: VPNSessionJournal

    init(model: AppModel, journal: VPNSessionJournal = VPNSessionJournal()) {
        self.model = model
        self.journal = journal
    }

    func start() throws {
        try server.start { [weak self] data in
            guard let self else { return Data("{\"ok\":false,\"error\":\"app_unavailable\"}".utf8) }
            return await self.handle(data)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recordState() }
        }
    }

    func recordState() {
        let stage = model.status.progress?.stage.rawValue ?? ""
        let key = "\(model.status.attemptID?.uuidString ?? ""):\(model.status.state.rawValue):\(stage):\(model.errorMessage != nil)"
        guard key != lastEvent else { return }
        lastEvent = key
        if let attempt = model.status.attemptID { lastAttempt = attempt }
        if model.status.state == .connected, connectedAt == nil { connectedAt = Date() }
        if model.status.state != .connected { connectedAt = nil }
        journal.append(state: model.status.state, stage: model.status.progress?.stage,
                       attempt: model.status.attemptID ?? lastAttempt, appSession: appSession, hasError: model.errorMessage != nil)
        if model.status.state == .disconnected { lastAttempt = nil }
        events.append(["time": ISO8601DateFormatter().string(from: Date()),
                       "state": model.status.state.rawValue, "stage": stage,
                       "hasError": model.errorMessage != nil])
        events = Array(events.suffix(200))
    }

    func handle(_ data: Data) -> Data {
        let response: [String: Any]
        do {
            let request = try JSONDecoder().decode(ControlRequest.self, from: data)
            response = execute(request)
        } catch { response = ["ok": false, "error": "invalid_request"] }
        return (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data()
    }

    private func execute(_ request: ControlRequest) -> [String: Any] {
        recordState()
        switch request.command {
        case "info":
            return connectionInfo()
        case "sessions":
            let history = journal.snapshot()
            return ["ok": true, "events": history, "sessions": journal.sessions(), "storageAvailable": journal.storageAvailable,
                    "retentionDays": 30, "maxEvents": 2000, "scope": "local_history", "redacted": true]
        case "status":
            return ["ok": true, "state": effectiveState,
                    "stage": model.status.progress?.stage.rawValue ?? "",
                    "attemptID": model.status.attemptID?.uuidString ?? "",
                    "challengeID": challengeID ?? "",
                    "challengeWaitRemainingSeconds": challengeRemaining as Any? ?? NSNull(),
                    "otpValiditySeconds": NSNull(),
                    "otpSubmitted": challengeID != nil && submittedChallenge == challengeID,
                    "hasError": model.errorMessage != nil,
                    "helperInstalled": model.isSystemHelperInstalled,
                    "hasStoredPassword": model.hasStoredPassword,
                    "operationPending": connecting || stopping || submittingOTP,
                    "scope": "current_app_session"]
        case "logs":
            return ["ok": true, "events": events,
                    "progress": model.status.progress?.events.map {
                        ["stage": $0.stage.rawValue, "time": ISO8601DateFormatter().string(from: $0.time)]
                    } ?? [], "scope": "current_app_session", "redacted": true]
        case "connect":
            guard !stopping, model.status.state != .disconnecting else { return failure("disconnect_in_progress") }
            if connecting || model.status.canDisconnect || model.isDiscoveringGroups {
                return ["ok": true, "accepted": false, "state": model.status.state.rawValue]
            }
            guard model.profile.validationErrors(hasStoredPassword: !model.password.isEmpty || model.hasStoredPassword).isEmpty else {
                return failure("configure_profile_in_app")
            }
            connecting = true
            let generation = commandGeneration
            Task {
                defer { connecting = false; recordState() }
                guard generation == commandGeneration else { return }
                await model.toggleConnection()
            }
            return ["ok": true, "accepted": true]
        case "disconnect":
            if stopping { return ["ok": true, "accepted": false] }
            stopping = true
            commandGeneration = UUID()
            Task {
                defer { stopping = false; recordState() }
                _ = await model.disconnect()
            }
            return ["ok": true, "accepted": true]
        case "otp":
            guard !stopping, !submittingOTP, model.status.state == .otpRequired,
                  request.attemptID == model.status.attemptID?.uuidString,
                  let challenge = challengeID, submittedChallenge != challenge,
                  request.challengeID == nil || request.challengeID == challenge,
                  challengeRemaining.map({ $0 > 0 }) ?? true,
                  let otp = request.otp, !otp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, otp.count <= 256 else { return failure("otp_not_requested_or_stale_attempt") }
            submittedChallenge = challenge
            submittingOTP = true
            Task {
                defer { submittingOTP = false; recordState() }
                guard !stopping, model.status.state == .otpRequired,
                      request.attemptID == model.status.attemptID?.uuidString else { return }
                model.otp = otp
                await model.submitOTP()
            }
            return ["ok": true, "accepted": true, "challengeID": challenge]
        default: return failure("unknown_command")
        }
    }

    private var challengeID: String? {
        guard model.status.state == .otpRequired, let attempt = model.status.attemptID else { return nil }
        return "\(attempt.uuidString):\(model.status.progress?.startedAt.timeIntervalSince1970 ?? 0)"
    }

    private var challengeRemaining: Int? {
        guard model.status.state == .otpRequired, let progress = model.status.progress else { return nil }
        return max(0, Int(ceil(60 - Date().timeIntervalSince(progress.startedAt))))
    }

    private var effectiveState: String {
        if let challengeID, submittedChallenge == challengeID { return TunnelState.authenticating.rawValue }
        return model.status.state.rawValue
    }

    private func connectionInfo() -> [String: Any] {
        let active = model.status.state == .connected
        let details = model.connectionDetails
        let network = model.networkInfo
        let policy = model.status.sessionPolicy
        var info: [String: Any] = ["ok": true, "state": effectiveState, "scope": "current_app_session", "active": active]
        guard active else { return info }
        info["connectedAt"] = connectedAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        info["durationSeconds"] = connectedAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0
        info["transport"] = details.isAvailable ? details.transport.rawValue : "unknown"
        info["cipher"] = details.cipherDescription ?? ""
        info["interface"] = network.interfaceName ?? ""
        info["mtu"] = network.mtu as Any? ?? NSNull()
        info["receivedBytes"] = model.trafficStats.receivedBytes
        info["transmittedBytes"] = model.trafficStats.transmittedBytes
        info["expiration"] = policy.expirationDate.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()
        info["remainingSeconds"] = policy.remainingTime(at: Date()).map { max(0, Int($0)) } as Any? ?? NSNull()
        info["idleTimeoutSeconds"] = policy.idleTimeout as Any? ?? NSNull()
        info["includedRouteCount"] = network.includedRoutes.count
        info["excludedRouteCount"] = network.excludedRoutes.count
        info["dnsServerCount"] = network.dnsServers.count
        return info
    }

    private func failure(_ code: String) -> [String: Any] { ["ok": false, "error": code] }
}

struct ControlRequest: Decodable {
    let command: String
    var otp: String? = nil
    var attemptID: String? = nil
    var challengeID: String? = nil
}
