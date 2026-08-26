import SwiftUI

@MainActor
struct RootView: View {
    @Bindable var model: AppModel
    @State private var showsNetworkInfo = false

    var body: some View {
        Group {
            if showsNetworkInfo {
                NetworkInfoView(
                    networkInfo: model.networkInfo,
                    isConnected: model.status.state == .connected,
                    isSystemHelperInstalled: model.isSystemHelperInstalled,
                    close: { showsNetworkInfo = false },
                    removeSystemHelper: {
                        Task {
                            await model.uninstallSystemHelper()
                            showsNetworkInfo = false
                        }
                    }
                )
            } else {
                connectionView
            }
        }
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
    }

    private var connectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.status.canDisconnect ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(model.status.canDisconnect ? Color.green : .accentColor)
                    .frame(width: 38, height: 38)
                    .background((model.status.canDisconnect ? Color.green : .accentColor).opacity(0.12), in: Circle())
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
                    TextField("vpn.example.com", text: $model.profile.gateway)
                        .textContentType(.URL)
                }
                inputRow("Логин") {
                    TextField("Логин", text: $model.profile.username)
                        .textContentType(.username)
                }
                inputRow("Пароль") {
                    SecureField(model.hasStoredPassword ? "Сохранён в Keychain" : "Пароль", text: $model.password)
                        .textContentType(.password)
                }

                inputRow("Группа") {
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
                        .disabled(model.isDiscoveringGroups || model.status.canDisconnect)
                        .help("Обновить группы")
                        .accessibilityLabel("Обновить группы")
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
                Button {
                    showsNetworkInfo = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Сведения об адресах")
                .accessibilityLabel("Сведения об адресах")

                if model.status.isBusy || model.isDiscoveringGroups {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Circle()
                        .fill(model.status.state == .connected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                }
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var connectButtonDisabled: Bool {
        model.status.isBusy || model.isDiscoveringGroups || model.profile.normalized().gateway.isEmpty
    }

    private var statusText: String {
        if model.isDiscoveringGroups { return "Получение групп…" }
        switch model.status.state {
        case .disconnected: return "Отключено"
        case .connecting, .authenticating: return "Подключение…"
        case .otpRequired: return "Введите OTP"
        case .connected: return "Подключено"
        case .disconnecting: return "Отключение…"
        case .failed: return "Ошибка подключения"
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
}
