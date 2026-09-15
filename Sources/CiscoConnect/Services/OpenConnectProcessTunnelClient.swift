import Foundation

/// IPC client for the bundled libopenconnect helper. Authentication forms are
/// processed by the helper; the GUI receives only typed state and group choices.
@MainActor
final class OpenConnectProcessTunnelClient: TunnelClient {
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let helperConnection: PrivilegedHelperConnection
    private let helperInstaller: PrivilegedHelperInstaller
    private var sessionDirectory: URL?
    private var statusFile: URL?
    private var otpFile: URL?
    private var pidFile: URL?
    private var sessionStartedAt = Date()
    private var attemptID: UUID?
    private var generation = UUID()
    private var startRequest: Task<Void, Error>?

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        helperConnection: PrivilegedHelperConnection,
        helperInstaller: PrivilegedHelperInstaller
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
        self.helperConnection = helperConnection
        self.helperInstaller = helperInstaller
    }

    func discoverGroups(gateway: URL) async throws -> [VPNGroup] {
        let paths = try createSession(mode: "discover", gateway: gateway, request: nil)
        defer { try? fileManager.removeItem(at: paths.directory) }
        let discovery = Process()
        discovery.executableURL = paths.helper
        discovery.arguments = [paths.request.path]
        try discovery.run()
        let completed = await wait(for: discovery, timeout: 45)
        if Task.isCancelled {
            if discovery.isRunning { discovery.terminate() }
            throw CancellationError()
        }
        guard completed else { discovery.terminate(); throw VPNError.authenticationTimeout }
        let snapshot = try readSnapshot(from: paths.status)
        if snapshot.state == "failed" { throw VPNError.helperFailure(snapshot.message) }
        return snapshot.groups
    }

    func connect(request: CiscoAuthenticationRequest) async throws -> TunnelStatus {
        guard sessionDirectory == nil else {
            return TunnelStatus(state: .connecting, message: "VPN connection is already starting", attemptID: request.attemptID)
        }
        let currentGeneration = generation
        try await helperInstaller.ensureInstalled(connection: helperConnection)
        try Task.checkCancellation()
        guard generation == currentGeneration else { throw CancellationError() }
        let paths = try createSession(mode: "connect", gateway: request.gateway, request: request)
        let payload = try Data(contentsOf: paths.request)
        try? fileManager.removeItem(at: paths.request)
        sessionStartedAt = Date()
        pidFile = paths.pid
        sessionDirectory = paths.directory
        statusFile = paths.status
        otpFile = paths.otp
        attemptID = request.attemptID
        let start = Task { try await helperConnection.connect(payload: payload) }
        startRequest = start
        do {
            try await start.value
        } catch {
            // Preserve the session until an explicit disconnect: a lost reply
            // does not prove that the daemon rejected the start request.
            if generation == currentGeneration { startRequest = nil }
            throw TunnelStartUnconfirmed(message: error.localizedDescription)
        }
        guard generation == currentGeneration else { throw CancellationError() }
        startRequest = nil
        return TunnelStatus(state: .authenticating, message: "Contacting VPN gateway", attemptID: request.attemptID)
    }

    func submitOTP(_ value: String) async throws {
        guard let otpFile, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VPNError.otpNotRequested }
        // The root helper protects the session directory from path substitution;
        // the pre-created OTP file remains user-owned and writable in place.
        try Data(value.utf8).write(to: otpFile)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: otpFile.path)
    }

    func disconnect() async throws -> TunnelStatus {
        generation = UUID()
        // Order stop after the bounded start reply, even when Cancel was
        // pressed while the daemon was accepting the connection.
        if let startRequest { _ = await startRequest.result }
        startRequest = nil
        if sessionDirectory != nil {
            try await helperConnection.disconnect()
        }
        cleanUp()
        return .disconnected
    }

    func currentStatus() async throws -> TunnelStatus {
        guard let attemptID, let statusFile else { return .disconnected }
        let snapshot: HelperSnapshot
        if fileManager.fileExists(atPath: statusFile.path) {
            do {
                snapshot = try readSnapshot(from: statusFile)
            } catch {
                throw VPNError.helperFailure("Не удалось прочитать состояние VPN helper")
            }
        } else if sessionDirectory != nil {
            try await checkSessionHealth(progress: nil)
            return TunnelStatus(state: .connecting, message: "Запуск системного VPN-компонента", attemptID: attemptID)
        } else {
            cleanUp()
            throw VPNError.helperFailure("VPN helper завершился до создания соединения")
        }
        if !["failed", "authenticationFailed", "sessionExpired", "disconnected"].contains(snapshot.state) {
            try await checkSessionHealth(progress: snapshot.progress)
        }
        switch snapshot.state {
        case "connected":
            return TunnelStatus(
                state: .connected,
                message: snapshot.message,
                attemptID: attemptID,
                networkInfo: snapshot.networkInfo,
                sessionPolicy: snapshot.sessionPolicy,
                connectionDetails: snapshot.connectionDetails,
                trafficStats: snapshot.trafficStats,
                progress: snapshot.progress
            )
        case "otpRequired": return TunnelStatus(state: .otpRequired, message: snapshot.message, attemptID: attemptID, progress: snapshot.progress)
        case "authenticating": return TunnelStatus(state: .authenticating, message: snapshot.message, attemptID: attemptID, progress: snapshot.progress)
        case "authenticationFailed":
            try await stopFailedSession(progress: snapshot.progress)
            throw AuthenticationFailure(message: snapshot.message, progress: snapshot.progress)
        case "failed":
            try await stopFailedSession(progress: snapshot.progress)
            throw TunnelDiagnosticFailure(message: snapshot.message, progress: snapshot.progress)
        case "sessionExpired":
            cleanUp()
            return TunnelStatus(
                state: .sessionExpired,
                message: snapshot.message,
                attemptID: attemptID,
                networkInfo: snapshot.networkInfo,
                sessionPolicy: snapshot.sessionPolicy,
                connectionDetails: snapshot.connectionDetails,
                trafficStats: snapshot.trafficStats,
                progress: snapshot.progress
            )
        case "disconnected": cleanUp(); return .disconnected
        default: return TunnelStatus(state: .connecting, message: snapshot.message, attemptID: attemptID, progress: snapshot.progress)
        }
    }

    private func createSession(mode: String, gateway: URL, request: CiscoAuthenticationRequest?) throws -> SessionPaths {
        let helper = try runtimePaths().helper
        let script = try runtimePaths().script
        let directory = temporaryDirectory.appending(path: "CiscoConnect-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let requestFile = directory.appending(path: "request.plist")
        let status = directory.appending(path: "status.plist")
        let otp = directory.appending(path: "otp")
        let pid = directory.appending(path: "pid")
        try Data().write(to: otp)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: otp.path)
        var payload: [String: Any] = ["mode": mode, "gateway": gateway.absoluteString, "statusPath": status.path, "otpPath": otp.path, "pidPath": pid.path, "vpncScript": script.path]
        if let request { payload.merge(["username": request.username, "password": request.password, "group": request.group]) { _, new in new } }
        guard (payload as NSDictionary).write(to: requestFile, atomically: true) else { throw VPNError.helperFailure("Could not prepare the helper request") }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestFile.path)
        return SessionPaths(directory: directory, helper: helper, request: requestFile, status: status, otp: otp, pid: pid)
    }

    private func runtimePaths() throws -> (helper: URL, script: URL) {
        guard let root = Bundle.main.resourceURL?.appending(path: "OpenConnect") else { throw VPNError.openConnectRuntimeMissing }
        let helper = root.appending(path: "bin/CiscoConnectHelper")
        let script = root.appending(path: "vpnc-script")
        guard fileManager.isExecutableFile(atPath: helper.path), fileManager.isExecutableFile(atPath: script.path) else { throw VPNError.openConnectRuntimeMissing }
        return (helper, script)
    }

    private func readSnapshot(from url: URL) throws -> HelperSnapshot {
        guard let dictionary = NSDictionary(contentsOf: url) as? [String: Any] else { throw VPNError.helperFailure("The VPN helper returned invalid state") }
        let groups: [VPNGroup] = (dictionary["groups"] as? [[String: String]] ?? []).compactMap { item -> VPNGroup? in
            guard let id = item["id"], let label = item["label"] else { return nil }
            return VPNGroup(id: id, label: label)
        }
        return HelperSnapshot(
            state: dictionary["state"] as? String ?? "failed",
            message: dictionary["message"] as? String ?? "VPN helper failed",
            groups: groups,
            networkInfo: VPNNetworkInfo(propertyList: dictionary["networkInfo"] as? [String: Any]),
            sessionPolicy: VPNSessionPolicy(
                expirationTimestamp: (dictionary["sessionExpiration"] as? NSNumber)?.doubleValue,
                idleTimeout: (dictionary["idleTimeoutSeconds"] as? NSNumber)?.doubleValue
            ),
            connectionDetails: VPNConnectionDetails(propertyList: dictionary["connectionDetails"] as? [String: Any]),
            trafficStats: VPNTrafficStats(propertyList: dictionary["trafficStats"] as? [String: Any]),
            progress: VPNConnectionProgress(propertyList: dictionary["progress"] as? [String: Any])
        )
    }

    private func wait(for process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !process.isRunning
    }

    private func checkSessionHealth(progress: VPNConnectionProgress?) async throws {
        do {
            try HelperSessionHealth.check(processAlive: helperProcessAlive, progress: progress, startedAt: sessionStartedAt, now: Date())
        } catch {
            try await stopFailedSession(progress: progress)
            throw error
        }
    }

    private func stopFailedSession(progress: VPNConnectionProgress?) async throws {
        if helperProcessAlive != false {
            do { try await helperConnection.disconnect() }
            catch {
                throw TunnelStartUnconfirmed(message: "Не удалось подтвердить остановку VPN после ошибки. Повторите отмену. " + error.localizedDescription, progress: progress)
            }
        }
        cleanUp()
    }

    private var helperProcessAlive: Bool? {
        guard let pidFile, let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func cleanUp() {
        attemptID = nil; statusFile = nil; otpFile = nil; pidFile = nil
        if let sessionDirectory {
            do {
                try fileManager.removeItem(at: sessionDirectory)
            } catch {
                let directory = sessionDirectory
                Task.detached {
                    for _ in 0..<10 {
                        try? await Task.sleep(for: .milliseconds(250))
                        do {
                            try FileManager.default.removeItem(at: directory)
                            return
                        } catch {}
                    }
                }
            }
        }
        sessionDirectory = nil
    }

}

private struct SessionPaths { let directory: URL; let helper: URL; let request: URL; let status: URL; let otp: URL; let pid: URL }
private struct HelperSnapshot {
    let state: String
    let message: String
    let groups: [VPNGroup]
    let networkInfo: VPNNetworkInfo
    let sessionPolicy: VPNSessionPolicy
    let connectionDetails: VPNConnectionDetails
    let trafficStats: VPNTrafficStats
    let progress: VPNConnectionProgress?
}
