import AppKit
import SwiftUI

enum MenuBarIconAppearance: Equatable {
    case offline
    case working
    case online
    case error

    init(tunnelState: TunnelState) {
        switch tunnelState {
        case .disconnected:
            self = .offline
        case .connecting, .authenticating, .otpRequired, .disconnecting:
            self = .working
        case .connected:
            self = .online
        case .failed:
            self = .error
        }
    }

    var color: Color {
        switch self {
        case .offline: Color(nsColor: .secondaryLabelColor)
        case .working: Color(nsColor: .systemYellow)
        case .online: Color(nsColor: .systemGreen)
        case .error: Color(nsColor: .systemRed)
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .offline: "OpenConnect Native: отключено"
        case .working: "OpenConnect Native: подключение"
        case .online: "OpenConnect Native: подключено"
        case .error: "OpenConnect Native: ошибка соединения"
        }
    }
}

/// A compact vector version of the app mark that remains legible at menu-bar size.
struct MenuBarStatusIcon: View {
    let tunnelState: TunnelState

    private var appearance: MenuBarIconAppearance {
        MenuBarIconAppearance(tunnelState: tunnelState)
    }

    var body: some View {
        OpenConnectMenuBarMark()
            .stroke(
                appearance.color,
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
            )
            .shadow(
                color: appearance == .offline ? .clear : appearance.color.opacity(0.65),
                radius: 1.5
            )
            .frame(width: 18, height: 18)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(appearance.accessibilityLabel)
    }
}

private struct OpenConnectMenuBarMark: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        var path = Path()
        path.move(to: point(0.18, 0.82))
        path.addLine(to: point(0.18, 0.43))
        path.addCurve(
            to: point(0.82, 0.43),
            control1: point(0.18, 0.10),
            control2: point(0.82, 0.10)
        )

        path.move(to: point(0.50, 0.43))
        path.addLine(to: point(0.50, 0.86))
        path.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.42,
            y: rect.minY + rect.height * 0.35,
            width: rect.width * 0.16,
            height: rect.height * 0.16
        ))

        path.move(to: point(0.82, 0.72))
        path.addLine(to: point(0.82, 0.84))
        return path
    }
}
