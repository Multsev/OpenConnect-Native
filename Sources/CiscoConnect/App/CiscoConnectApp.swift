import SwiftUI

@main
@MainActor
struct CiscoConnectApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @State private var appModel = AppModel.makeLive()
    @AppStorage(AppPresentationPreferences.menuBarOnlyKey) private var menuBarOnly = false

    var body: some Scene {
        Window("OpenConnect Native", id: "main") {
            RootView(
                model: appModel,
                menuBarOnly: $menuBarOnly,
                presentation: .window
            )
        }
        .defaultSize(width: 460, height: 230)
        .defaultPosition(.center)
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unifiedCompact)

        MenuBarExtra {
            RootView(
                model: appModel,
                menuBarOnly: $menuBarOnly,
                presentation: .menuBar
            )
        } label: {
            MenuBarStatusIcon(tunnelState: appModel.status.state)
        }
        .menuBarExtraStyle(.window)
    }
}
