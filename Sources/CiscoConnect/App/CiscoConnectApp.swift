import SwiftUI

@main
@MainActor
struct CiscoConnectApp: App {
    @State private var appModel = AppModel.makeLive()

    var body: some Scene {
        WindowGroup("CiscoConnect") {
            RootView(model: appModel)
                .frame(minWidth: 520, idealWidth: 560, minHeight: 300, idealHeight: 340)
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
