import SwiftUI

/// Keeps arbitrarily long gateway/helper errors inside a bounded sheet.
/// The dismissal action stays outside the scrolling message.
struct VPNErrorView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ошибка VPN", systemImage: "exclamationmark.triangle")
                .font(.headline)
            ScrollView {
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Spacer()
                Button("Закрыть", action: dismiss)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("dismissVPNError")
            }
        }
        .padding(16)
        .frame(width: 432, height: 240)
        .tint(OpenConnectPalette.accent)
    }
}
