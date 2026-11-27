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
        Image(nsImage: Self.image(for: tunnelState))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(appearance.accessibilityLabel)
    }

    static func image(for tunnelState: TunnelState, phase: Double = 0) -> NSImage {
        let appearance = MenuBarIconAppearance(tunnelState: tunnelState)
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            let globe = NSRect(x: 1, y: 2, width: 15, height: 15)
            let mesh = NSBezierPath(ovalIn: globe)
            mesh.appendOval(in: globe.insetBy(dx: 3.8 + 2.7 * sin(phase), dy: 0))
            mesh.move(to: CGPoint(x: globe.minX, y: globe.midY))
            mesh.line(to: CGPoint(x: globe.maxX, y: globe.midY))
            appearance.nsColor.setStroke()
            mesh.lineWidth = 1.35
            mesh.stroke()

            let body = NSBezierPath(roundedRect: NSRect(x: 11, y: 0.8, width: 8, height: 6.8),
                                    xRadius: 1.5, yRadius: 1.5)
            let shackle = NSBezierPath(ovalIn: NSRect(x: 12.6, y: 4.1, width: 4.8, height: 6.8))
            NSColor.black.withAlphaComponent(0.75).setStroke()
            shackle.lineWidth = 3.4
            shackle.stroke()
            body.lineWidth = 2
            body.stroke()
            appearance.nsColor.setStroke()
            shackle.lineWidth = 1.5
            shackle.stroke()
            appearance.nsColor.setFill()
            body.fill()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 14.2, y: 3.1, width: 1.6, height: 2.2)).fill()
            return true
        }
        image.isTemplate = appearance == .offline
        return image
    }
}
