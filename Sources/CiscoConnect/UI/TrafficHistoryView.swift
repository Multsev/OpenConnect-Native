import Charts
import SwiftUI

struct TrafficHistoryView: View {
    let history: TrafficHistory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelIsVisible) private var isVisible

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let latest = history.samples.last {
                HStack {
                    rateLabel("↓ Приём", latest.received, .teal)
                    Spacer()
                    rateLabel("↑ Передача", latest.transmitted, .indigo)
                }
                Chart(history.samples) { sample in
                    line(sample, value: sample.received, label: "Приём", color: .teal)
                    line(sample, value: sample.transmitted, label: "Передача", color: .indigo)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartXScale(domain: (latest.id - 30)...latest.id)
                .frame(height: 34)
                .animation(reduceMotion || !isVisible ? nil : .easeOut(duration: 0.25), value: latest.id)
                .accessibilityLabel("Трафик VPN за последние 30 секунд")
            } else {
                Text("Ожидание статистики трафика…").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func line(_ sample: TrafficRate, value: Double, label: String, color: Color) -> some ChartContent {
        LineMark(x: .value("Время", sample.id), y: .value("Байт/с", value), series: .value("Поток", label))
            .foregroundStyle(color)
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
