import SwiftUI

@main
@MainActor
struct CiscoConnectApp: App {
    @State private var appModel = AppModel.makeLive()

    var body: some Scene {
        Window("OpenConnect Native", id: "main") {
            RootView(model: appModel)
        }
        .defaultSize(width: 460, height: 230)
        .defaultPosition(.center)
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandMenu("VPN") {
                Button(appModel.status.canDisconnect ? "Отключиться" : "Подключиться") {
                    Task { await appModel.toggleConnection() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(appModel.status.isBusy)
            }
        }
    }
}
