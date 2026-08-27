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

    @MainActor
    static func hideMainWindow() {
        mainWindow?.orderOut(nil)
    }

    @MainActor
    static func showMainWindow() {
        applyActivationPolicy(menuBarOnly: false)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    @MainActor
    private static var mainWindow: NSWindow? {
        NSApplication.shared.windows.first { window in
            window.title == "OpenConnect Native" && !(window is NSPanel)
        }
    }
}

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let appModel = AppModel.makeLive()
    private var menuBarPopoverController: MenuBarPopoverController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        AppPresentationPreferences.applyActivationPolicy(
            menuBarOnly: AppPresentationPreferences.isMenuBarOnly
        )
        menuBarPopoverController = MenuBarPopoverController(model: appModel)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
