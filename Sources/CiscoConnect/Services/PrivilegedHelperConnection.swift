import Foundation
import XPC

@MainActor
final class PrivilegedHelperConnection {
    static let serviceName = "com.max.openconnectnative.helper"

    func connect(payload: Data) async throws {
        try await send(command: "connect", payload: payload)
    }

    func disconnect() async throws {
        try await send(command: "disconnect", payload: nil)
    }

    func ping() async throws {
        try await send(command: "ping", payload: nil)
    }

    private func send(command: String, payload: Data?) async throws {
        let connection = makeConnection()
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "command", command)
        if let payload {
            payload.withUnsafeBytes { bytes in
                if let baseAddress = bytes.baseAddress {
                    xpc_dictionary_set_data(message, "payload", baseAddress, bytes.count)
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            xpc_connection_send_message_with_reply(connection, message, .main) { reply in
                defer { xpc_connection_cancel(connection) }
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
                    continuation.resume(throwing: VPNError.helperFailure("Системный VPN-компонент недоступен"))
                    return
                }
                guard xpc_dictionary_get_bool(reply, "accepted") else {
                    let text = xpc_dictionary_get_string(reply, "message").map(String.init(cString:))
                    continuation.resume(throwing: VPNError.helperFailure(text ?? "Системный VPN-компонент отклонил запрос"))
                    return
                }
                continuation.resume()
            }
        }
    }

    private func makeConnection() -> xpc_connection_t {
        let connection = xpc_connection_create_mach_service(Self.serviceName, .main, 0)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        return connection
    }
}
