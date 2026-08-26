import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var showsSettings = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                Image(systemName: model.status.canDisconnect ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(model.status.canDisconnect ? Color.green : .accentColor)
                    .frame(width: 72, height: 72)
                    .background((model.status.canDisconnect ? Color.green : .accentColor).opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 12) {
                    Text("AnyConnect VPN").font(.title3.weight(.semibold))
                    if model.availableGroups.isEmpty {
                        Text(model.profile.normalized().gateway.isEmpty ? "Configure a gateway in Settings" : model.profile.normalized().gateway)
                            .lineLimit(1).foregroundStyle(.secondary)
                    } else {
                        Picker("VPN group", selection: Binding(
                            get: { model.profile.group },
                            set: { model.selectGroup($0) }
                        )) {
                            ForEach(model.availableGroups) { group in Text(group.label).tag(group.id) }
                        }
                        .labelsHidden()
                        .accessibilityLabel("VPN group")
                    }
                    HStack {
                        if model.status.state == .otpRequired {
                            SecureField("One-time code", text: $model.otp)
                                .textContentType(.oneTimeCode)
                                .onSubmit { Task { await model.submitOTP() } }
                            Button("Submit") { Task { await model.submitOTP() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.otp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        } else {
                            Text(model.isDiscoveringGroups ? "Loading VPN groups…" : (model.status.canDisconnect ? "VPN is active" : "Ready to connect"))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.status.state != .otpRequired {
                            Button(model.status.canDisconnect ? "Disconnect" : "Connect") { Task { await model.toggleConnection() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.status.isBusy || model.isDiscoveringGroups || model.profile.normalized().gateway.isEmpty)
                        }
                    }
                }
            }
            .padding(22)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.quaternary) }
            .padding(24)
            Divider()
            HStack {
                Button("Settings", systemImage: "gearshape") { showsSettings = true }.labelStyle(.iconOnly).help("VPN settings")
                Spacer()
                Text(model.status.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.padding(.horizontal, 16).frame(height: 46)
        }
        .sheet(isPresented: $showsSettings) { ProfileView(model: model).frame(width: 440, height: 360) }
        .alert("VPN connection", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}
