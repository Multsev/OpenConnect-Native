import AppKit
import Foundation
import UserNotifications

enum AppPresentationPreferences {
    static let menuBarOnlyKey = "menuBarOnly"
    static let menuBarIntroductionKey = "didShowMenuBarIntroduction"

    static var isMenuBarOnly: Bool {
        UserDefaults.standard.bool(forKey: menuBarOnlyKey)
    }

    @MainActor
    static func applyActivationPolicy(menuBarOnly: Bool) {
        NSApplication.shared.setActivationPolicy(menuBarOnly ? .accessory : .regular)
        if !menuBarOnly {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            AppPresentationPreferences.applyActivationPolicy(
                menuBarOnly: AppPresentationPreferences.isMenuBarOnly
            )
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
