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
            // Both callbacks run on the main queue. The first result wins;
            // cancelling XPC can itself deliver a late error reply.
            let reply = HelperReplyCompletion(continuation: continuation)
            let timeout = DispatchWorkItem {
                reply.finish(.failure(VPNError.helperFailure("Системный VPN-компонент не ответил за 5 секунд. Повторите отключение или завершите приложение.")))
                xpc_connection_cancel(connection)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
            xpc_connection_send_message_with_reply(connection, message, .main) { response in
                timeout.cancel()
                defer { xpc_connection_cancel(connection) }
                guard xpc_get_type(response) == XPC_TYPE_DICTIONARY else {
                    reply.finish(.failure(VPNError.helperFailure("Системный VPN-компонент недоступен")))
                    return
                }
                guard xpc_dictionary_get_bool(response, "accepted") else {
                    let text = xpc_dictionary_get_string(response, "message").map(String.init(cString:))
                    reply.finish(.failure(VPNError.helperFailure(text ?? "Системный VPN-компонент отклонил запрос")))
                    return
                }
                reply.finish(.success(()))
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

/// Owned exclusively by the main queue used for XPC replies and deadlines.
final class HelperReplyCompletion {
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}
