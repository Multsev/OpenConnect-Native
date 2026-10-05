import Foundation
import Security

protocol VPNProfileStore {
    func load() -> VPNProfile
    func save(_ profile: VPNProfile) throws
}

final class UserDefaultsVPNProfileStore: VPNProfileStore {
    private let key = "vpn-profile"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> VPNProfile {
        guard let data = defaults.data(forKey: key), let profile = try? JSONDecoder().decode(VPNProfile.self, from: data) else {
            return VPNProfile()
        }
        return profile
    }

    func save(_ profile: VPNProfile) throws {
        defaults.set(try JSONEncoder().encode(profile.normalized()), forKey: key)
    }
}

protocol PasswordStore: AnyObject {
    var hasPassword: Bool { get }
    func read() throws -> String?
    func save(_ password: String) throws
    func delete() throws
}

final class KeychainPasswordStore: PasswordStore {
    private let service = "com.max.ciscoconnect"
    private let account = "primary-vpn-password"

    var hasPassword: Bool { (try? read())?.isEmpty == false }

    func read() throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status) }
        return String(data: data, encoding: .utf8)
    }

    func save(_ password: String) throws {
        if password.isEmpty { return try delete() }
        let data = Data(password.utf8)
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let attributes: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status)
        }
    }

    func delete() throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status) }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    init(_ status: OSStatus) { self.status = status }
    var errorDescription: String? { "Keychain could not save the VPN password (\(status))." }
}


/// Serializes potentially blocking Security.framework calls away from UI work.
enum PasswordStoreWorker {
    private static let queue = DispatchQueue(label: "com.max.ciscoconnect.keychain", qos: .userInitiated)

    static func read(_ store: PasswordStore) async throws -> String? {
        let started = PerformanceMeasurements.start()
        defer { PerformanceMeasurements.shared.record(.keychainRead, since: started) }
        return try await perform { try store.read() }
    }

    static func save(_ password: String, to store: PasswordStore) async throws {
        try await perform { try store.save(password) }
    }

    private static func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
}
