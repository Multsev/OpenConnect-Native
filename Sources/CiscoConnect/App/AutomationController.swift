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

    init(model: AppModel) { self.model = model }

    func start() throws {
        try server.start { [weak self] data in
            guard let self else { return Data("{\"ok\":false,\"error\":\"app_unavailable\"}".utf8) }
            return await self.handle(data)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recordState() }
        }
    }

    private func recordState() {
        let stage = model.status.progress?.stage.rawValue ?? ""
        let key = "\(model.status.state.rawValue):\(stage):\(model.errorMessage != nil)"
        guard key != lastEvent else { return }
        lastEvent = key
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
        case "status":
            return ["ok": true, "state": model.status.state.rawValue,
                    "stage": model.status.progress?.stage.rawValue ?? "",
                    "attemptID": model.status.attemptID?.uuidString ?? "",
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
                  let otp = request.otp, !otp.isEmpty, otp.count <= 256 else { return failure("otp_not_requested_or_stale_attempt") }
            submittingOTP = true
            Task {
                defer { submittingOTP = false; recordState() }
                guard !stopping, model.status.state == .otpRequired,
                      request.attemptID == model.status.attemptID?.uuidString else { return }
                model.otp = otp
                await model.submitOTP()
            }
            return ["ok": true, "accepted": true]
        default: return failure("unknown_command")
        }
    }

    private func failure(_ code: String) -> [String: Any] { ["ok": false, "error": code] }
}

struct ControlRequest: Decodable {
    let command: String
    var otp: String? = nil
    var attemptID: String? = nil
}
