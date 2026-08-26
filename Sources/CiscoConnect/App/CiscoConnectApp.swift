import SwiftUI

@main
@MainActor
struct CiscoConnectApp: App {
    @State private var appModel = AppModel.makeLive()

    var body: some Scene {
        MenuBarExtra {
            RootView(model: appModel)
        } label: {
            Label("OpenConnect Native", systemImage: menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: String {
        switch appModel.status.state {
        case .connected:
            return "lock.open.fill"
        case .connecting, .authenticating, .otpRequired, .disconnecting:
            return "arrow.triangle.2.circlepath"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .disconnected:
            return "lock.fill"
        }
    }
}
