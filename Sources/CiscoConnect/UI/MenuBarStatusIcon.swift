import AppKit
import SwiftUI

enum MenuBarIconAppearance: Equatable {
    case offline
    case working
    case online
    case expired
    case error

    init(tunnelState: TunnelState) {
        switch tunnelState {
        case .disconnected:
            self = .offline
        case .connecting, .authenticating, .otpRequired, .disconnecting:
            self = .working
        case .connected:
            self = .online
        case .sessionExpired:
            self = .expired
        case .failed:
            self = .error
        }
    }

    var nsColor: NSColor {
        switch self {
        case .offline: .secondaryLabelColor
        case .working: .systemYellow
        case .online: .systemGreen
        case .expired, .error: .systemRed
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .offline: "OpenConnect Native: отключено"
        case .working: "OpenConnect Native: подключение"
        case .online: "OpenConnect Native: подключено"
        case .expired: "OpenConnect Native: срок сеанса истёк"
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
        Image(nsImage: menuBarImage)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(appearance.accessibilityLabel)
    }

    private var menuBarImage: NSImage {
        let appearance = appearance
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            let path = OpenConnectMenuBarMark.path(in: rect.insetBy(dx: 1, dy: 1))
            let context = NSGraphicsContext.current?.cgContext
            context?.saveGState()
            if appearance != .offline {
                context?.setShadow(
                    offset: .zero,
                    blur: 2.5,
                    color: appearance.nsColor.withAlphaComponent(0.7).cgColor
                )
            }
            appearance.nsColor.setStroke()
            path.lineWidth = 2.2
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
            context?.restoreGState()
            return true
        }
        // State colors must remain visible instead of inheriting the menu-bar tint.
        image.isTemplate = false
        return image
    }
}

private enum OpenConnectMenuBarMark {
    static func path(in rect: CGRect) -> NSBezierPath {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }

        let path = NSBezierPath()
        path.move(to: point(0.18, 0.82))
        path.line(to: point(0.18, 0.43))
        path.curve(
            to: point(0.82, 0.43),
            controlPoint1: point(0.18, 0.10),
            controlPoint2: point(0.82, 0.10)
        )

        path.move(to: point(0.50, 0.43))
        path.line(to: point(0.50, 0.86))
        path.appendOval(in: CGRect(
            x: rect.minX + rect.width * 0.42,
            y: rect.minY + rect.height * 0.35,
            width: rect.width * 0.16,
            height: rect.height * 0.16
        ))

        path.move(to: point(0.82, 0.72))
        path.line(to: point(0.82, 0.84))
        return path
    }
}
