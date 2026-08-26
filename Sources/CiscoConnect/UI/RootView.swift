import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarSection? = .connection

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationTitle("CiscoConnect")
        } detail: {
            switch selection ?? .connection {
            case .connection: ConnectionView(model: model)
            case .profile: ProfileView(model: model)
            }
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case connection, profile
    var id: String { rawValue }
    var title: String { self == .connection ? "Connection" : "VPN Profile" }
    var symbol: String { self == .connection ? "lock.shield" : "slider.horizontal.3" }
}

