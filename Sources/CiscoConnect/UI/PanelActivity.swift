import Observation
import SwiftUI

@Observable
@MainActor
final class PanelActivity {
    var isVisible = false
}

private struct PanelVisibilityKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var panelIsVisible: Bool {
        get { self[PanelVisibilityKey.self] }
        set { self[PanelVisibilityKey.self] = newValue }
    }
}

/// Retains the form while removing periodic schedules when its panel is hidden.
struct VisibleTimeline<Content: View>: View {
    @Environment(\.panelIsVisible) private var isVisible
    let interval: TimeInterval
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        if isVisible {
            TimelineView(.periodic(from: .now, by: interval)) { context in
                content(context.date)
            }
        } else {
            content(Date())
        }
    }
}
