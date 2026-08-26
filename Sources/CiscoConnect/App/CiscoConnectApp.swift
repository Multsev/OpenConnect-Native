import SwiftUI

@main
@MainActor
struct CiscoConnectApp: App {
    @State private var appModel = AppModel.makeLive()

    var body: some Scene {
        MenuBarExtra {
            RootView(model: appModel)
        } label: {
            MenuBarStatusIcon(tunnelState: appModel.status.state)
        }
        .menuBarExtraStyle(.window)
    }
}
