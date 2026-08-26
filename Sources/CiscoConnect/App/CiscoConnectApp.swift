import SwiftUI

@main
@MainActor
struct CiscoConnectApp: App {
    @State private var appModel = AppModel.makeLive()

    var body: some Scene {
        WindowGroup("CiscoConnect") {
            RootView(model: appModel)
                .frame(minWidth: 760, minHeight: 520)
        }
        .commands {
            CommandMenu("VPN") {
                Button(appModel.status.canDisconnect ? "Disconnect" : "Connect") {
                    Task { await appModel.toggleConnection() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(appModel.status.isBusy)
            }
        }
    }
}
