import AppKit
import UserNotifications

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let appModel = AppModel.makeLive()
    private var menuBarPopoverController: MenuBarPopoverController?
    private var automationController: AutomationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        NSApplication.shared.setActivationPolicy(.accessory)
        menuBarPopoverController = MenuBarPopoverController(model: appModel)
        Task {
            let journal = await Task.detached(priority: .utility) {
                VPNSessionJournal(directory: VPNSessionJournal.directory)
            }.value
            let automation = AutomationController(model: appModel, journal: journal)
            do {
                try automation.start()
                automationController = automation
            } catch {
                NSLog("Local VPN automation unavailable (%@)", String(describing: type(of: error)))
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBarPopoverController?.showPopover()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        automationController?.recordState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            let needsDisconnect = appModel.status.canDisconnect || appModel.status.isBusy || appModel.isDiscoveringGroups
            let disconnected = needsDisconnect ? await appModel.disconnect() : true
            if !disconnected {
                let alert = NSAlert()
                alert.messageText = "Не удалось подтвердить отключение VPN"
                alert.informativeText = "Системный компонент не ответил. Можно завершить приложение или остаться и повторить отключение."
                alert.addButton(withTitle: "Завершить приложение")
                alert.addButton(withTitle: "Остаться")
                let shouldQuit = alert.runModal() == .alertFirstButtonReturn
                isTerminating = false
                if shouldQuit { await flushJournal() }
                sender.reply(toApplicationShouldTerminate: shouldQuit)
            } else {
                await flushJournal()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    private func flushJournal() async {
        automationController?.recordState()
        await automationController?.flushJournal()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
