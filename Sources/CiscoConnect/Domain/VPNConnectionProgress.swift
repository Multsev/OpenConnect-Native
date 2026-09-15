import Foundation

/// A whitelist of local stages, never raw OpenConnect messages or auth forms.
struct VPNConnectionProgress: Equatable, Sendable {
    enum Stage: String, Sendable {
        case preparing, contacting, credentials, waitingOTP, checkingOTP
        case tlsTunnel, interface, dns, networkCheck, dtls, connected

        var title: String {
            switch self {
            case .preparing: "Подготовка подключения"
            case .contacting: "Связь со шлюзом"
            case .credentials: "Проверка логина и пароля"
            case .waitingOTP: "Ожидание OTP"
            case .checkingOTP: "Проверка OTP на шлюзе"
            case .tlsTunnel: "Создание TLS-туннеля"
            case .interface: "Настройка интерфейса и маршрутов"
            case .dns: "Настройка корпоративного DNS"
            case .networkCheck: "Проверка сети macOS"
            case .dtls: "Настройка DTLS"
            case .connected: "Подключено"
            }
        }

        var timeout: TimeInterval? {
            self == .connected ? nil : (self == .waitingOTP ? 60 : 45)
        }
    }

    struct Event: Equatable, Sendable, Identifiable {
        var id: String { "\(stage.rawValue):\(time.timeIntervalSince1970)" }
        let stage: Stage
        let time: Date
    }

    let stage: Stage
    let startedAt: Date
    let events: [Event]

    init?(propertyList: [String: Any]?) {
        guard let propertyList,
              let raw = propertyList["stage"] as? String, let stage = Stage(rawValue: raw),
              let timestamp = propertyList["stageStartedAt"] as? Double,
              timestamp.isFinite, timestamp > 0 else { return nil }
        self.stage = stage
        startedAt = Date(timeIntervalSince1970: timestamp)
        events = (propertyList["events"] as? [[String: Any]] ?? []).suffix(20).compactMap {
            guard let raw = $0["stage"] as? String, let stage = Stage(rawValue: raw),
                  let time = $0["time"] as? Double, time.isFinite, time > 0 else { return nil }
            return Event(stage: stage, time: Date(timeIntervalSince1970: time))
        }
    }
}

struct TunnelDiagnosticFailure: LocalizedError {
    let message: String
    let progress: VPNConnectionProgress?
    var errorDescription: String? {
        guard let progress else { return message }
        return "\(message)\nПоследний этап: \(progress.stage.title)."
    }
}

/// The status file survives a daemon crash, so it is not proof of liveness.
struct HelperSessionHealth {
    static func check(processAlive: Bool?, progress: VPNConnectionProgress?, startedAt: Date, now: Date) throws {
        if processAlive == false {
            throw TunnelDiagnosticFailure(message: "Системный VPN-компонент неожиданно завершился. Подключение остановлено.", progress: progress)
        }
        if processAlive == nil && now.timeIntervalSince(startedAt) > 10 {
            throw TunnelDiagnosticFailure(message: "Системный VPN-компонент не начал работу за 10 секунд.", progress: progress)
        }
        let timeout = progress?.stage.timeout ?? (progress == nil ? 45 : nil)
        if let timeout, now.timeIntervalSince(progress?.startedAt ?? startedAt) > timeout + 5 {
            throw TunnelDiagnosticFailure(message: "Превышено время ожидания на этапе подключения (\(Int(timeout)) секунд).", progress: progress)
        }
    }
}
