import AppKit
import SwiftUI

@MainActor
struct RootView: View {
    @Environment(\.panelIsVisible) private var panelIsVisible
    @Bindable var model: AppModel
    @State private var showsConnectionDetails = false
    @State private var showsProfileSettings = false
    @State private var showsAbout = false
    @State private var showsHelperRemovalConfirmation = false
    @FocusState private var otpFocused: Bool

    var body: some View {
        Group {
            if showsConnectionDetails {
                ConnectionDetailsView(
                    networkInfo: model.networkInfo, connectionDetails: model.connectionDetails,
                    trafficStats: model.trafficStats, sessionPolicy: model.status.sessionPolicy,
                    isConnected: model.status.state == .connected,
                    close: { showsConnectionDetails = false }, progress: model.status.progress,
                    progressIsActive: model.status.canDisconnect && model.status.state != .connected,
                    errorMessage: model.errorMessage
                ).frame(height: 202)
            } else if showsAbout {
                aboutView
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if showsProfileSettings || needsConfiguration {
                        ProfileSettingsView(model: model) {
                            if model.saveProfileSettings() { showsProfileSettings = false }
                        }
                    } else {
                        header
                    }
                    statusView
                    if model.status.state == .otpRequired { otpView }
                    actions
                }
            }
        }
        .tint(OpenConnectPalette.accent)
        .padding(14)
        .frame(width: 460, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Удалить системный компонент?", isPresented: $showsHelperRemovalConfirmation) {
            Button("Удалить", role: .destructive) { Task { await model.uninstallSystemHelper() } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("VPN будет отключён. macOS один раз запросит пароль администратора и удалит helper и LaunchDaemon.")
        }
    }

    var needsConfiguration: Bool {
        !model.isLoadingSavedPassword && !model.hasConfiguredProfile
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().scaledToFit().frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(string: model.profile.normalized().gateway)?.host ?? "VPN")
                    .font(.headline).lineLimit(1)
                Text(model.profile.username.isEmpty ? "OpenConnect Native" : model.profile.username)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            settingsMenu
        }
    }

    private var settingsMenu: some View {
        Menu {
            Button("Настройки подключения") { showsProfileSettings = true }
            Button("О приложении") { showsAbout = true }
            Divider()
            Button("Удалить системный компонент…", role: .destructive) {
                showsHelperRemovalConfirmation = true
            }.disabled(!model.isSystemHelperInstalled)
            Divider()
            Button("Завершить приложение") { NSApplication.shared.terminate(nil) }
        } label: { Image(systemName: "gearshape") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Настройки").accessibilityLabel("Настройки")
    }

    private var statusView: some View {
        VisibleTimeline(interval: 30) { date in
            HStack(alignment: .top, spacing: 8) {
                if model.errorMessage == nil && (model.status.state.isBusy || model.isDiscoveringGroups) && model.status.state != .otpRequired && panelIsVisible {
                    ProgressView().controlSize(.small)
                } else {
                    Circle().fill(statusIndicatorColor).frame(width: 7, height: 7).padding(.top, 5)
                }
                Button { showsConnectionDetails = true } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(statusText(at: date)).font(.callout.weight(.medium)).lineLimit(1)
                        if model.status.state == .connected {
                            if let remaining = model.status.sessionPolicy.remainingDescription(at: date) {
                                Text("До завершения: " + remaining).font(.caption)
                            }
                            if model.connectionDetails.isAvailable && model.connectionDetails.transport == .tls {
                                Text("Соединение через TLS").font(.caption)
                            }
                        }
                    }.foregroundStyle(statusColor(at: date))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(statusAccessibilityLabel(at: date))
                .help("Нажмите для подробностей")
                Spacer(minLength: 0)
            }
        }
    }

    private var otpView: some View {
        HStack(spacing: 8) {
            TextField("Код OTP", text: $model.otp)
                .textContentType(.oneTimeCode).focused($otpFocused)
                .accessibilityIdentifier("otpCode")
                .textFieldStyle(.roundedBorder)
                .task(id: panelIsVisible) {
                    await Task.yield()
                    guard panelIsVisible, !Task.isCancelled else { return }
                    otpFocused = true
                }
                .onDisappear { otpFocused = false }
                .onSubmit(submitOTP)
            Button("Отправить", action: submitOTP)
                .disabled(model.otp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var actions: some View {
        HStack {
            if showsProfileSettings || needsConfiguration { settingsMenu }
            Button("Сведения") { showsConnectionDetails = true }.buttonStyle(.borderless)
            Spacer()
            if model.status.state == .connected {
                connectionButton.buttonStyle(.bordered).tint(.gray)
            } else {
                connectionButton.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private var connectionButton: some View {
        Button(model.connectionButtonTitle) {
            showsProfileSettings = false
            model.connectionButtonPressed()
        }
        .disabled(model.connectionButtonDisabled || model.isLoadingSavedPassword)
    }

    private var aboutView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("OpenConnect Native").font(.headline)
                Spacer()
                Button("Назад") { showsAbout = false }.buttonStyle(.borderless)
            }
            Text("Совместимо с Cisco AnyConnect").font(.callout)
            Text("Версия " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    func statusText(at date: Date) -> String {
        if let error = model.errorMessage { return VPNErrorSummary.text(for: error) }
        if model.isDiscoveringGroups { return "Получение групп…" }
        switch model.status.state {
        case .disconnected: return "Отключено"
        case .connecting, .authenticating: return (model.status.progress?.stage.title ?? "Подготовка подключения") + "…"
        case .otpRequired: return "Введите OTP"
        case .connected:
            if model.status.sessionPolicy.hasExpired(at: date) { return "Сеанс завершается…" }
            return "Подключено"
        case .disconnecting: return "Отключение…"
        case .sessionExpired: return "Сеанс завершён"
        case .failed: return "Ошибка подключения"
        }
    }

    func statusColor(at date: Date) -> Color {
        if model.errorMessage != nil { return .red }
        switch model.status.state {
        case .sessionExpired, .failed:
            return .red
        case .connected where model.status.sessionPolicy.hasExpired(at: date):
            return .orange
        case .connected where model.status.sessionPolicy.isExpiringSoon(at: date):
            return .orange
        case .connected where model.connectionDetails.isAvailable && model.connectionDetails.transport == .tls:
            return .orange
        case .connected:
            return .green
        case .otpRequired:
            return .orange
        default:
            return .secondary
        }
    }

    private var statusIndicatorColor: Color {
        if model.errorMessage != nil { return .red }
        switch model.status.state {
        case .connected:
            let policy = model.status.sessionPolicy
            return policy.hasExpired(at: Date()) || policy.isExpiringSoon(at: Date()) ||
                (model.connectionDetails.isAvailable && model.connectionDetails.transport == .tls) ? .orange : .green
        case .sessionExpired, .failed:
            return .red
        case .otpRequired:
            return .orange
        default:
            return .secondary.opacity(0.5)
        }
    }

    private func statusAccessibilityLabel(at date: Date) -> String {
        if model.errorMessage != nil { return statusText(at: date) + ". Нажмите для подробностей" }
        switch model.status.state {
        case .connected:
            if model.status.sessionPolicy.hasExpired(at: date) { return "Срок VPN-сеанса истёк, ожидается завершение подключения" }
            guard let remaining = model.status.sessionPolicy.remainingDescription(at: date) else { return "VPN подключён" }
            return "VPN подключён, до завершения сеанса осталось \(remaining)"
        case .sessionExpired:
            return "Срок VPN-сеанса истёк"
        default:
            return statusText(at: date)
        }
    }

    private func submitOTP() { Task { await model.submitOTP() } }
}
