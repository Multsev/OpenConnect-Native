import SwiftUI

/// A compact, timer-free activity indicator for the VPN connection phase.
struct PingPongConnectionIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            Canvas { graphicsContext, size in
                drawFrame(
                    in: &graphicsContext,
                    size: size,
                    phase: reduceMotion ? 0 : phase(at: context.date)
                )
            }
        }
        .frame(width: 27, height: 12)
        .accessibilityHidden(true)
    }

    private func phase(at date: Date) -> Double {
        let cycleDuration = 1.15
        let progress = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
        return progress * .pi * 2
    }

    private func drawFrame(
        in context: inout GraphicsContext,
        size: CGSize,
        phase: Double
    ) {
        let paddleSize = CGSize(width: 2.5, height: 8)
        let ballDiameter = 3.5
        let edgeInset = 1.0
        let ballTravel = size.width - (edgeInset * 2) - (paddleSize.width * 2) - ballDiameter
        let horizontalProgress = (sin(phase) + 1) / 2
        let ballX = edgeInset + paddleSize.width + (ballTravel * horizontalProgress)
        let ballY = ((size.height - ballDiameter) / 2) + (sin(phase * 2) * 1.15)
        let leftY = ((size.height - paddleSize.height) / 2) + (max(0, -sin(phase)) * 1.4)
        let rightY = ((size.height - paddleSize.height) / 2) + (max(0, sin(phase)) * 1.4)
        let color = OpenConnectPalette.accent

        context.fill(
            Path(roundedRect: CGRect(x: edgeInset, y: leftY, width: paddleSize.width, height: paddleSize.height), cornerRadius: 1.25),
            with: .color(color.opacity(0.78))
        )
        context.fill(
            Path(roundedRect: CGRect(x: size.width - edgeInset - paddleSize.width, y: rightY, width: paddleSize.width, height: paddleSize.height), cornerRadius: 1.25),
            with: .color(color.opacity(0.78))
        )
        context.fill(
            Path(ellipseIn: CGRect(x: ballX, y: ballY, width: ballDiameter, height: ballDiameter)),
            with: .color(color)
        )
    }
}
