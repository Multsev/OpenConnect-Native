import AppKit
import SwiftUI

@MainActor
struct RootView: View {
    enum Presentation {
        case window
        case menuBar
    }

    @Bindable var model: AppModel
    @Binding var menuBarOnly: Bool
    let presentation: Presentation
    @AppStorage(AppPresentationPreferences.menuBarIntroductionKey) private var didShowMenuBarIntroduction = false
    @State private var showsConnectionDetails = false
    @State private var showsMenuBarIntroduction = false
    @State private var showsHelperRemovalConfirmation = false
    @State private var showsPassword = false

    var body: some View {
        Group {
            if showsConnectionDetails {
                ConnectionDetailsView(
                    networkInfo: model.networkInfo,
                    connectionDetails: model.connectionDetails,
                    trafficStats: model.trafficStats,
                    sessionPolicy: model.status.sessionPolicy,
                    isConnected: model.status.state == .connected,
                    close: { showsConnectionDetails = false }
                )
            } else {
                connectionView
            }
        }
        .tint(OpenConnectPalette.accent)
        .padding(14)
        .frame(width: 460, height: 230, alignment: .topLeading)
        .alert("VPN", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("Закрыть", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Приложение находится в строке меню", isPresented: $showsMenuBarIntroduction) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text("OpenConnect Native также доступен по цветному значку в верхней строке macOS. Режим можно изменить через шестерёнку → «Только строка меню».")
        }
        .alert("Удалить системный компонент?", isPresented: $showsHelperRemovalConfirmation) {
            Button("Удалить", role: .destructive) {
                Task { await model.uninstallSystemHelper() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("VPN будет отключён. macOS один раз запросит пароль администратора и удалит helper и LaunchDaemon.")
        }
        .task {
            guard presentation == .window else { return }
            if menuBarOnly {
                AppPresentationPreferences.hideMainWindow()
            } else if !didShowMenuBarIntroduction {
                didShowMenuBarIntroduction = true
                showsMenuBarIntroduction = true
            }
        }
    }

    private var connectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.status.canDisconnect ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(OpenConnectPalette.accent)
                    .frame(width: 38, height: 38)
                    .background(OpenConnectPalette.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("OpenConnect Native")
                        .font(.headline)
                    Text("Совместимо с Cisco AnyConnect")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                inputRow("Шлюз") {
                    if profileFieldsLocked {
                        SelectableReadOnlyField(text: model.profile.gateway)
                    } else {
                        TextField("vpn.example.com", text: $model.profile.gateway)
                            .textContentType(.URL)
                    }
                }
                inputRow("Логин") {
                    if profileFieldsLocked {
                        SelectableReadOnlyField(text: model.profile.username)
                    } else {
                        TextField("Логин", text: $model.profile.username)
                            .textContentType(.username)
                    }
                }
                inputRow("Пароль") {
                    HStack(spacing: 6) {
                        if profileFieldsLocked {
                            if showsPassword {
                                SelectableReadOnlyField(text: model.password)
                            } else {
                                SelectableReadOnlySecureField(text: model.password)
                            }
                        } else {
                            Group {
                                if showsPassword {
                                    TextField("Пароль", text: $model.password)
                                } else {
                                    SecureField("Пароль", text: $model.password)
                                }
                            }
                            .textContentType(.password)
                        }

                        Button {
                            showsPassword.toggle()
                        } label: {
                            Image(systemName: showsPassword ? "eye.slash" : "eye")
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.password.isEmpty)
                        .help(showsPassword ? "Скрыть пароль" : "Показать пароль")
                        .accessibilityLabel(showsPassword ? "Скрыть пароль" : "Показать пароль")
                    }
                }

                inputRow("Группа") {
                    if profileFieldsLocked {
                        SelectableReadOnlyField(text: model.profile.group)
                    } else {
                        HStack(spacing: 6) {
                            if !model.availableGroups.isEmpty {
                                Picker("Группа", selection: Binding(
                                    get: { model.profile.group },
                                    set: { model.selectGroup($0) }
                                )) {
                                    ForEach(model.availableGroups) { group in
                                        Text(group.label).tag(group.id)
                                    }
                                }
                                .labelsHidden()
                                .accessibilityLabel("Группа")
                            } else {
                                TextField("Группа", text: $model.profile.group)
                            }

                            Button {
                                Task { await model.refreshGroups() }
                            } label: {
                                if model.isDiscoveringGroups {
                                    ProgressView()
                                        .controlSize(.small)
                                        .frame(width: 14, height: 14)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.isDiscoveringGroups)
                            .help("Обновить группы")
                            .accessibilityLabel("Обновить группы")
                        }
                    }
                }

                if model.status.state == .otpRequired {
                    inputRow("OTP") {
                        HStack(spacing: 8) {
                            SecureField("Код", text: $model.otp)
                                .textContentType(.oneTimeCode)
                                .onSubmit(submitOTP)
                            Button("Отправить", action: submitOTP)
                                .disabled(model.otp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            Divider()

            HStack(spacing: 8) {
                Menu {
                    Button("Сведения") {
                        showsConnectionDetails = true
                    }
                    Toggle("Только строка меню", isOn: Binding(
                        get: { menuBarOnly },
                        set: setMenuBarOnly
                    ))
                    Divider()
                    Button("Удалить системный компонент…", role: .destructive) {
                        showsHelperRemovalConfirmation = true
                    }
                    .disabled(!model.isSystemHelperInstalled)
                    Divider()
                    Button("Завершить приложение") {
                        NSApplication.shared.terminate(nil)
                    }
                    .disabled(model.status.canDisconnect)
                } label: {
                    Image(systemName: "gearshape")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Настройки")
                .accessibilityLabel("Настройки")

                if showsConnectionAnimation {
                    PingPongConnectionIndicator()
                        .help("Устанавливается VPN-соединение")
                } else if model.status.isBusy || model.isDiscoveringGroups {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Circle()
                        .fill(statusIndicatorColor)
                        .frame(width: 7, height: 7)
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Button {
                        showsConnectionDetails = true
                    } label: {
                        HStack(spacing: 3) {
                            Text(statusText(at: context.date))
                                .lineLimit(1)
                            if model.status.state == .connected {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .semibold))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(statusColor(at: context.date))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(statusAccessibilityLabel(at: context.date))
                    .help("Показать сведения о подключении")
                }
                Spacer(minLength: 8)
                Button(model.status.canDisconnect ? "Отключиться" : "Подключиться") {
                    Task { await model.toggleConnection() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(connectButtonDisabled)

                Text("v\(appVersion)")
                    .font(.system(size: 9, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Версия приложения \(appVersion)")
            }
        }
        .overlay(alignment: .topTrailing) {
            ApplicationIconWatermark()
                .padding(.trailing, 2)
                .offset(y: -3)
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var connectButtonDisabled: Bool {
        model.status.isBusy || model.isDiscoveringGroups || model.profile.normalized().gateway.isEmpty
    }

    private var profileFieldsLocked: Bool {
        model.status.state.locksProfileFields
    }

    private var showsConnectionAnimation: Bool {
        model.status.state == .connecting || model.status.state == .authenticating
    }

    private func statusText(at date: Date) -> String {
        if model.isDiscoveringGroups { return "Получение групп…" }
        switch model.status.state {
        case .disconnected: return "Отключено"
        case .connecting, .authenticating: return "Подключение…"
        case .otpRequired: return "Введите OTP"
        case .connected:
            if model.status.sessionPolicy.hasExpired(at: date) { return "Сеанс завершается…" }
            var parts = ["Подключено"]
            if model.connectionDetails.isAvailable { parts.append(model.connectionDetails.transport.rawValue) }
            if let remaining = model.status.sessionPolicy.remainingDescription(at: date) { parts.append(remaining) }
            return parts.joined(separator: " · ")
        case .disconnecting: return "Отключение…"
        case .sessionExpired: return "Сеанс завершён"
        case .failed: return "Ошибка подключения"
        }
    }

    private func statusColor(at date: Date) -> Color {
        switch model.status.state {
        case .sessionExpired, .failed:
            return .red
        case .connected where model.status.sessionPolicy.hasExpired(at: date):
            return .orange
        case .connected where model.status.sessionPolicy.isExpiringSoon(at: date):
            return .orange
        case .connected where model.connectionDetails.isAvailable && model.connectionDetails.transport == .tls:
            return .orange
        default:
            return .secondary
        }
    }

    private var statusIndicatorColor: Color {
        switch model.status.state {
        case .connected:
            return .green
        case .sessionExpired, .failed:
            return .red
        default:
            return .secondary.opacity(0.5)
        }
    }

    private func statusAccessibilityLabel(at date: Date) -> String {
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

    private func inputRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            content()
                .frame(maxWidth: .infinity)
        }
    }

    private func submitOTP() {
        Task { await model.submitOTP() }
    }

    private func setMenuBarOnly(_ enabled: Bool) {
        menuBarOnly = enabled
        AppPresentationPreferences.applyActivationPolicy(menuBarOnly: enabled)
        if enabled {
            AppPresentationPreferences.hideMainWindow()
        } else {
            AppPresentationPreferences.showMainWindow()
        }
    }
}

private struct ApplicationIconWatermark: View {
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 54, height: 54)
            .opacity(0.28)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
