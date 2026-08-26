import SwiftUI

struct ProfileView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("Cisco AnyConnect gateway") {
                TextField("HTTPS gateway", text: $model.profile.gateway)
                    .textContentType(.URL)
                TextField("Group / authgroup", text: $model.profile.group)
                TextField("Username", text: $model.profile.username)
                    .textContentType(.username)
            }
            Section("Primary credential") {
                SecureField(model.hasStoredPassword ? "Replace password" : "Password", text: $model.password)
                    .textContentType(.password)
                LabeledContent("Storage") {
                    Text(model.hasStoredPassword ? "Saved in Keychain" : "No password saved")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Save profile") { model.saveProfile() }
                    .disabled(model.isSaving)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("VPN Profile")
        .padding()
    }
}

