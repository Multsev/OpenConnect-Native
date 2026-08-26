import AppKit
import Foundation

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

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppPresentationPreferences.applyActivationPolicy(
                menuBarOnly: AppPresentationPreferences.isMenuBarOnly
            )
        }
    }
}
