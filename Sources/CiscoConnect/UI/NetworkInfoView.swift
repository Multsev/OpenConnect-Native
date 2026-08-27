import SwiftUI

struct ConnectionDetailsView: View {
    private enum Page {
        case summary
        case network
        case certificate
    }

    let networkInfo: VPNNetworkInfo
    let connectionDetails: VPNConnectionDetails
    let trafficStats: VPNTrafficStats
    let sessionPolicy: VPNSessionPolicy
    let isConnected: Bool
    let close: () -> Void

    @State private var page: Page = .summary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            content
        }
        .tint(OpenConnectPalette.blue)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: goBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help(page == .summary ? "Назад к подключению" : "Назад к сведениям")
            .accessibilityLabel("Назад")

            VStack(alignment: .leading, spacing: 1) {
                Text(pageTitle)
                    .font(.headline)
                Text(isConnected ? "Текущее подключение" : "Последние данные этого запуска")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if page == .summary {
                ConnectionQualityBadge(details: connectionDetails, isConnected: isConnected)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .summary:
            ConnectionSummaryView(
                networkInfo: networkInfo,
                details: connectionDetails,
                trafficStats: trafficStats,
                sessionPolicy: sessionPolicy,
                showNetwork: { page = .network },
                showCertificate: { page = .certificate }
            )
        case .network:
            NetworkPolicyDetailsView(networkInfo: networkInfo)
        case .certificate:
            CertificateDetailsView(details: connectionDetails)
        }
    }

    private var pageTitle: String {
        switch page {
        case .summary: "Сведения"
        case .network: "Маршруты и DNS"
        case .certificate: "Сертификат"
        }
    }

    private func goBack() {
        if page == .summary { close() }
        else { page = .summary }
    }
}

private struct ConnectionSummaryView: View {
    let networkInfo: VPNNetworkInfo
    let details: VPNConnectionDetails
    let trafficStats: VPNTrafficStats
    let sessionPolicy: VPNSessionPolicy
    let showNetwork: () -> Void
    let showCertificate: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                if let notice = details.notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                CompactDetailRow("Соединение", value: connectionDescription)
                if let endpoint = details.endpointDescription {
                    CompactDetailRow("Шлюз", value: endpoint, monospaced: true)
                }
                if let interfaceDescription {
                    CompactDetailRow("Интерфейс", value: interfaceDescription, monospaced: true)
                }

                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let sessionDescription = sessionDescription(at: context.date) {
                        CompactDetailRow("Сеанс", value: sessionDescription)
                    }
                }

                CompactDetailRow(
                    "Трафик",
                    value: "↓ \(trafficStats.receivedDescription)   ↑ \(trafficStats.transmittedDescription)",
                    monospaced: true
                )
                CompactDetailRow("Сеть", value: networkSummary)

                if let serverMessage = details.serverMessage {
                    Text(serverMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(serverMessage)
                        .padding(.top, 1)
                }

                HStack(spacing: 8) {
                    Button("Маршруты и DNS", action: showNetwork)
                    Button("Сертификат", action: showCertificate)
                        .disabled(details.certificateFingerprint == nil)
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var connectionDescription: String {
        guard details.isAvailable else { return "Данные появятся после подключения" }
        var parts = [details.transport.rawValue]
        if let cipher = details.cipherDescription { parts.append(cipher) }
        return parts.joined(separator: " · ")
    }

    private var interfaceDescription: String? {
        var parts: [String] = []
        if let interfaceName = networkInfo.interfaceName { parts.append(interfaceName) }
        if let mtu = networkInfo.mtu { parts.append("MTU \(mtu)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func sessionDescription(at date: Date) -> String? {
        var parts: [String] = []
        if let remaining = sessionPolicy.remainingDescription(at: date) { parts.append("осталось \(remaining)") }
        if let idle = sessionPolicy.idleTimeoutDescription { parts.append("простой \(idle)") }
        if let rekey = details.rekeyDescription { parts.append("ключи \(rekey)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var networkSummary: String {
        if networkInfo.usesSplitTunnel {
            return "Только корпоративные сети · \(networkInfo.includedRoutes.count) маршрутов"
        }
        if !networkInfo.excludedRoutes.isEmpty {
            return "Весь трафик, кроме \(networkInfo.excludedRoutes.count) исключений"
        }
        return "Весь трафик через VPN"
    }
}

private struct NetworkPolicyDetailsView: View {
    let networkInfo: VPNNetworkInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                Label(routeSummary, systemImage: networkInfo.usesSplitTunnel ? "arrow.triangle.branch" : "network")
                    .font(.caption.weight(.semibold))
                DetailValuesSection("Через VPN", values: networkInfo.includedRoutes)
                DetailValuesSection("Мимо VPN", values: networkInfo.excludedRoutes)
                DetailValuesSection("Домены", values: networkInfo.domains)
                DetailValuesSection("DNS", values: networkInfo.dnsServers)
                DetailValuesSection("WINS", values: networkInfo.nbnsServers)
                DetailValuesSection("Адрес VPN", values: networkInfo.vpnAddresses)
                DetailValuesSection("Маска", values: networkInfo.vpnNetmasks)
                if let proxyPAC = networkInfo.proxyPAC {
                    DetailValuesSection("Proxy PAC", values: [proxyPAC])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var routeSummary: String {
        if networkInfo.usesSplitTunnel { return "Через VPN идут только указанные сети" }
        if !networkInfo.excludedRoutes.isEmpty { return "Через VPN идёт весь трафик, кроме исключений" }
        return "Весь трафик идёт через VPN"
    }
}

private struct CertificateDetailsView: View {
    let details: VPNConnectionDetails

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let host = details.gatewayHost { CompactDetailRow("Имя", value: host) }
                if let endpoint = details.endpointDescription { CompactDetailRow("Адрес", value: endpoint, monospaced: true) }
                if let cipher = details.cipherDescription { CompactDetailRow("Шифрование", value: cipher) }
                if let fingerprint = details.certificateFingerprint {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Отпечаток")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(fingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } else {
                    Text("Шлюз не предоставил доступные сведения о сертификате.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ConnectionQualityBadge: View {
    let details: VPNConnectionDetails
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        guard isConnected else { return .secondary }
        guard details.isAvailable else { return OpenConnectPalette.green }
        return details.transport == .dtls ? OpenConnectPalette.green : .orange
    }

    private var label: String {
        guard isConnected else { return "Неактивно" }
        guard details.isAvailable else { return "Активно" }
        return details.transport.rawValue
    }
}

private struct CompactDetailRow: View {
    let title: String
    let value: String
    let monospaced: Bool

    init(_ title: String, value: String, monospaced: Bool = false) {
        self.title = title
        self.value = value
        self.monospaced = monospaced
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)
            Text(value)
                .fontDesign(monospaced ? .monospaced : .default)
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

private struct DetailValuesSection: View {
    let title: String
    let values: [String]

    init(_ title: String, values: [String]) {
        self.title = title
        self.values = values
    }

    var body: some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
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

enum OpenConnectPalette {
    static let blue = Color(red: 0.10, green: 0.60, blue: 0.78)
    static let green = Color(red: 0.18, green: 0.84, blue: 0.45)
}
