import SwiftUI

struct ConnectionView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Connection status") {
                LabeledContent("Status", value: model.status.message)
                LabeledContent("Gateway", value: model.profile.normalized().gateway.isEmpty ? "Not configured" : model.profile.normalized().gateway)
            }
            Section("One-time password") {
                SecureField("OTP (never saved)", text: $model.otp)
                    .textContentType(.oneTimeCode)
                Text("Provide the code only for this connection attempt. Leave it empty if the gateway asks for it later.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button(model.status.canDisconnect ? "Disconnect" : "Connect") {
                    Task { await model.toggleConnection() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.status.isBusy)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connection")
        .padding()
        .alert("VPN connection", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

