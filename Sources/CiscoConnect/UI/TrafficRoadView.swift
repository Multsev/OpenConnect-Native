import SwiftUI

struct TrafficRoadView: View {
    let history: TrafficHistory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelIsVisible) private var isVisible

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let latest = history.latest {
                HStack {
                    rateLabel("↓ Приём", latest.received, .teal)
                    Spacer()
                    rateLabel("↑ Передача", latest.transmitted, .indigo)
                }
                TrafficRoad(received: latest.received, transmitted: latest.transmitted,
                            animates: isVisible && !reduceMotion)
            } else {
                Text("Ожидание статистики трафика…").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func rateLabel(_ title: String, _ rate: Double, _ color: Color) -> some View {
        let formatted = Int64(clamping: UInt64(min(rate.rounded(), Double(Int64.max))))
            .formatted(.byteCount(style: .file, allowedUnits: [.bytes, .kb, .mb, .gb]))
        return VStack(alignment: .leading, spacing: 1) {
            Text(title).foregroundStyle(color)
            Text(formatted + "/с").monospacedDigit()
        }
    }
}

/// A fixed visual scale for throughput. VPN peers do not advertise channel capacity.
struct TrafficLane {
    let count: Int
    let speed: Double

    init(bytesPerSecond: Double) {
        guard bytesPerSecond > 0 else {
            count = 0
            speed = 0
            return
        }
        let density = min(log1p(bytesPerSecond / 4096) / log1p(1024), 1)
        count = max(1, Int(ceil(16 * density)))
        speed = 4 + 72 * pow(1 - density, 1.6)
    }
}

private struct RoadMotion {
    var distance = 0.0
    var time = ProcessInfo.processInfo.systemUptime
    var speed = 0.0

    func offset(at now: TimeInterval) -> Double { distance + max(0, now - time) * speed }

    mutating func changeSpeed(to newSpeed: Double, at now: TimeInterval) {
        distance = offset(at: now)
        time = now
        speed = newSpeed
    }
}

struct TrafficRoad: View {
    let received: Double
    let transmitted: Double
    let animates: Bool
    @State private var inbound = RoadMotion()
    @State private var outbound = RoadMotion()

    var body: some View {
        let rx = TrafficLane(bytesPerSecond: received)
        let tx = TrafficLane(bytesPerSecond: transmitted)
        let moving = animates && rx.count + tx.count > 0
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !moving)) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            Canvas { context, size in
                let bounds = CGRect(origin: .zero, size: size)
                let asphalt = Path(roundedRect: bounds, cornerRadius: 6)
                context.clip(to: asphalt)
                context.fill(asphalt, with: .color(.primary.opacity(0.07)))
                var divider = Path()
                divider.move(to: CGPoint(x: 0, y: size.height / 2))
                divider.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(divider, with: .color(.secondary.opacity(0.55)),
                               style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                drawLane(context, width: size.width, y: size.height * 0.25, count: rx.count,
                         offset: inbound.offset(at: now), direction: 1, color: .teal)
                drawLane(context, width: size.width, y: size.height * 0.75, count: tx.count,
                         offset: outbound.offset(at: now), direction: -1, color: .indigo)
            }
        }
        .frame(height: 38)
        .onChange(of: [moving ? rx.speed : 0, moving ? tx.speed : 0], initial: true) { _, speeds in
            let now = ProcessInfo.processInfo.systemUptime
            inbound.changeSpeed(to: speeds[0], at: now)
            outbound.changeSpeed(to: speeds[1], at: now)
        }
        .accessibilityHidden(true)
    }

    private func drawLane(_ context: GraphicsContext, width: CGFloat, y: CGFloat, count: Int,
                          offset: Double, direction: CGFloat, color: Color) {
        // Spread the first cars across the road. New cars fill existing gaps.
        let slots = [3, 11, 7, 15, 1, 9, 5, 13, 0, 8, 4, 12, 2, 10, 6, 14]
        let track = width + 16
        for slot in slots.prefix(count) {
            let phase = (track * (Double(slot) + 0.5) / 16 + offset).truncatingRemainder(dividingBy: track)
            let center = direction > 0 ? phase - 8 : width + 8 - phase
            let body = CGRect(x: center - 7, y: y - 3.75, width: 14, height: 7.5)
            context.fill(Path(roundedRect: body, cornerRadius: 2.8), with: .color(color))
            let windshield = CGRect(x: center + direction * 2 - 1.4, y: y - 2.6, width: 2.8, height: 5.2)
            context.fill(Path(roundedRect: windshield, cornerRadius: 0.9), with: .color(.white.opacity(0.9)))
        }
    }
}
