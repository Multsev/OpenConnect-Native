import Foundation
import UserNotifications

@MainActor
protocol SessionExpirationNotifying: AnyObject {
    func schedule(expiration: Date) async
    func cancel()
}

@MainActor
final class UserNotificationSessionExpirationNotifier: SessionExpirationNotifying {
    private static let pendingIdentifiersKey = "vpn-session-notification-identifiers"

    private struct Identifiers {
        let fifteenMinutes: String
        let fiveMinutes: String
        let expired: String

        init(expiration: Date) {
            let suffix = String(Int(expiration.timeIntervalSince1970))
            fifteenMinutes = "vpn-session-expiration-15-minutes-\(suffix)"
            fiveMinutes = "vpn-session-expiration-5-minutes-\(suffix)"
            expired = "vpn-session-expired-\(suffix)"
        }

        var all: [String] { [fifteenMinutes, fiveMinutes, expired] }
    }

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private var currentExpiration: Date?

    init(center: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
    }

    func schedule(expiration: Date) async {
        cancel()
        currentExpiration = expiration
        let identifiers = Identifiers(expiration: expiration)
        defaults.set(identifiers.all, forKey: Self.pendingIdentifiersKey)
        guard expiration > Date(), await notificationsAreAllowed(), currentExpiration == expiration else { return }

        await addWarning(
            identifier: identifiers.fifteenMinutes,
            title: "VPN-сеанс скоро завершится",
            body: "До повторного подключения осталось 15 минут.",
            deliveryDate: expiration.addingTimeInterval(-15 * 60)
        )
        guard currentExpiration == expiration else {
            center.removePendingNotificationRequests(withIdentifiers: identifiers.all)
            return
        }
        await addWarning(
            identifier: identifiers.fiveMinutes,
            title: "VPN-сеанс скоро завершится",
            body: "До повторного подключения осталось 5 минут.",
            deliveryDate: expiration.addingTimeInterval(-5 * 60)
        )
        guard currentExpiration == expiration else {
            center.removePendingNotificationRequests(withIdentifiers: identifiers.all)
            return
        }
        await addWarning(
            identifier: identifiers.expired,
            title: "VPN-сеанс завершён",
            body: "Для продолжения подключитесь снова и введите OTP.",
            deliveryDate: expiration
        )
        if currentExpiration != expiration {
            center.removePendingNotificationRequests(withIdentifiers: identifiers.all)
        }
    }

    func cancel() {
        currentExpiration = nil
        let identifiers = defaults.stringArray(forKey: Self.pendingIdentifiersKey) ?? []
        if !identifiers.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
        defaults.removeObject(forKey: Self.pendingIdentifiersKey)
    }

    private func notificationsAreAllowed() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func addWarning(
        identifier: String,
        title: String,
        body: String,
        deliveryDate: Date
    ) async {
        let delay = deliveryDate.timeIntervalSinceNow
        guard delay >= 1 else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "vpn-session"
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }
}

@MainActor
final class NoopSessionExpirationNotifier: SessionExpirationNotifying {
    func schedule(expiration: Date) async {}
    func cancel() {}
}
