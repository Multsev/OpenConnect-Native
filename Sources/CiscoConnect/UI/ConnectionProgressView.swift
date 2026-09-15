import SwiftUI

struct ConnectionProgressView: View {
    let progress: VPNConnectionProgress
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isActive ? "Текущий этап" : "Последний этап")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(progress.stage.title)
                .font(.callout.weight(.medium))
            if isActive, let timeout = progress.stage.timeout {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Ожидание: \(max(0, Int(context.date.timeIntervalSince(progress.startedAt)))) с · предел \(Int(timeout)) с")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("Этапы этой попытки")
                .font(.caption.weight(.semibold))
            ForEach(progress.events) { event in
                HStack(alignment: .top, spacing: 8) {
                    Text(event.time, style: .time)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(event.stage.title)
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
