import AppKit
import SwiftUI

@MainActor
struct ProfileSettingsView: View {
    @Environment(\.panelIsVisible) private var panelIsVisible
    @Bindable var model: AppModel
    let done: () -> Void
    @State private var showsPassword = false
    private var profileFieldsLocked: Bool { model.status.state.locksProfileFields }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Настройки подключения").font(.headline)
                Spacer()
                Button("Готово", action: done).buttonStyle(.borderless)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                inputRow("Шлюз") {
                    ProfileTextField(text: $model.profile.gateway, placeholder: "vpn.example.com", editable: !profileFieldsLocked)
                }
                inputRow("Логин") {
                    ProfileTextField(text: $model.profile.username, placeholder: "Логин", editable: !profileFieldsLocked)
                }
                inputRow("Пароль") {
                    HStack(spacing: 6) {
                        ProfileTextField(text: $model.password, placeholder: "Пароль", editable: !profileFieldsLocked, secure: !showsPassword)
                            .id(showsPassword)
                        Button {
                            showsPassword.toggle()
                        } label: {
                            Image(systemName: showsPassword ? "eye.slash" : "eye")
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)
                        .disabled(profileFieldsLocked || model.password.isEmpty)
                        .help(showsPassword ? "Скрыть пароль" : "Показать пароль")
                        .accessibilityLabel(showsPassword ? "Скрыть пароль" : "Показать пароль")
                    }
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
                            .disabled(profileFieldsLocked)
                        } else {
                            ProfileTextField(text: $model.profile.group, placeholder: "Группа", editable: !profileFieldsLocked)
                        }

                        Button {
                            Task { await model.refreshGroups() }
                        } label: {
                            Group {
                                if model.isDiscoveringGroups && panelIsVisible {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.borderless)
                        .disabled(profileFieldsLocked || model.isDiscoveringGroups)
                        .help("Обновить группы")
                        .accessibilityLabel("Обновить группы")
                    }
                }

            }
            .textFieldStyle(.roundedBorder)
            if profileFieldsLocked {
                Text("Параметры можно изменить после отключения")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(VPNErrorSummary.text(for: error))
                    .font(.caption).foregroundStyle(.red)
            }
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

}
