import Foundation

/// Short, fixed labels keep server diagnostics out of the compact status row.
enum VPNErrorSummary {
    static func text(for message: String) -> String {
        let text = message.lowercased()
        if text.contains("заполните") { return "Заполните настройки" }
        if text.contains("отключ") && text.contains("подтверд") {
            return "Отключение не подтверждено"
        }
        if text.contains("ошибка обмена со шлюзом") {
            return "Ошибка связи со шлюзом"
        }
        if text.contains("превышено время") || text.contains("timeout") || text.contains("timed out") {
            return "Превышено время ожидания"
        }
        if text.contains("сертификат") || text.contains("certificate") {
            return "Ошибка сертификата"
        }
        if text.contains("keychain") { return "Ошибка доступа к паролю" }
        if text.contains("компонент") || text.contains("helper") {
            return "Ошибка VPN-компонента"
        }
        return "Ошибка подключения"
    }
}
