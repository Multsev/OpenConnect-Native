import Foundation

/// The persisted provider configuration deliberately contains no secrets.
@objcMembers
final class TunnelConfiguration: NSObject {
    let gateway: String
    let group: String
    let username: String
    let password: String
    let otp: String

    init?(persistent: [String: Any]?, launchOptions: [String: NSObject]?) {
        guard
            let gateway = persistent?["gateway"] as? String,
            let username = launchOptions?["username"] as? String,
            let password = launchOptions?["password"] as? String
        else { return nil }
        self.gateway = gateway
        self.group = persistent?["group"] as? String ?? ""
        self.username = username
        self.password = password
        self.otp = launchOptions?["otp"] as? String ?? ""
    }
}
