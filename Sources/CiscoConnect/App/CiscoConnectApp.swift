import SwiftUI

@main
@MainActor
struct CiscoConnectApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate

    // The status-item controller owns the only application interface.
    // A Settings scene keeps the SwiftUI lifecycle without creating a launch window.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
