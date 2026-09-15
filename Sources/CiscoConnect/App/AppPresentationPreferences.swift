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

    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        guard appModel.status.canDisconnect || appModel.status.isBusy || appModel.isDiscoveringGroups else {
            return .terminateNow
        }
        isTerminating = true
        Task {
            let disconnected = await appModel.disconnect()
            if !disconnected {
                let alert = NSAlert()
                alert.messageText = "Не удалось подтвердить отключение VPN"
                alert.informativeText = "Системный компонент не ответил. Можно завершить приложение или остаться и повторить отключение."
                alert.addButton(withTitle: "Завершить приложение")
                alert.addButton(withTitle: "Остаться")
                let shouldQuit = alert.runModal() == .alertFirstButtonReturn
                isTerminating = false
                sender.reply(toApplicationShouldTerminate: shouldQuit)
            } else {
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
