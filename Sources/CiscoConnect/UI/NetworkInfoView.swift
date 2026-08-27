import SwiftUI

struct NetworkInfoView: View {
    let networkInfo: VPNNetworkInfo
    let sessionPolicy: VPNSessionPolicy
    let isConnected: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: close) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Назад")
                .accessibilityLabel("Назад")

                VStack(alignment: .leading, spacing: 1) {
                    Text("Сведения об адресах")
                        .font(.headline)
                    Text(isConnected ? "Данные текущего подключения" : "Последние данные этого запуска")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if sessionPolicy.isAvailable {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Сеанс")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if sessionPolicy.expirationDate != nil {
                                TimelineView(.periodic(from: .now, by: 30)) { context in
                                    Text(sessionExpirationText(at: context.date))
                                        .font(.caption)
                                        .foregroundStyle(sessionPolicy.isExpiringSoon(at: context.date) ? Color.orange : Color.primary)
                                }
                            }
                            if let idleTimeout = sessionPolicy.idleTimeoutDescription {
                                Text("Простой: \(idleTimeout)")
                                    .font(.caption)
                            }
                        }
                        Divider()
                    }

                    if networkInfo.isAvailable {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(
                                routeSummary,
                                systemImage: networkInfo.usesSplitTunnel ? "arrow.triangle.branch" : "network"
                            )
                            .font(.callout.weight(.medium))

                            infoSection("Через VPN", values: networkInfo.includedRoutes)
                            infoSection("Мимо VPN", values: networkInfo.excludedRoutes)
                            infoSection("Домены", values: networkInfo.domains)
                            infoSection("DNS", values: networkInfo.dnsServers)
                            infoSection("Адрес VPN", values: networkInfo.vpnAddresses)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Данные маршрутов появятся после подключения.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func sessionExpirationText(at date: Date) -> String {
        if sessionPolicy.hasExpired(at: date) { return "Срок истёк" }
        guard let remaining = sessionPolicy.remainingDescription(at: date) else { return "Срок не передан" }
        return "Осталось: \(remaining)"
    }

    private var routeSummary: String {
        if networkInfo.usesSplitTunnel {
            return "Через VPN идут только указанные сети"
        }
        if !networkInfo.excludedRoutes.isEmpty {
            return "Через VPN идёт весь трафик, кроме исключений"
        }
        return "Весь трафик идёт через VPN"
    }

    @ViewBuilder
    private func infoSection(_ title: String, values: [String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }
}
