import Foundation

/// IPC client for the bundled libopenconnect helper. Authentication forms are
/// processed by the helper; the GUI receives only typed state and group choices.
@MainActor
final class OpenConnectProcessTunnelClient: TunnelClient {
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private var process: Process?
    private var sessionDirectory: URL?
    private var statusFile: URL?
    private var otpFile: URL?
    private var attemptID: UUID?

    init(fileManager: FileManager = .default, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    func discoverGroups(gateway: URL) async throws -> [VPNGroup] {
        let paths = try createSession(mode: "discover", gateway: gateway, request: nil)
        defer { try? fileManager.removeItem(at: paths.directory) }
        let discovery = Process()
        discovery.executableURL = paths.helper
        discovery.arguments = [paths.request.path]
        try discovery.run()
        let completed = await wait(for: discovery, timeout: 45)
        guard completed else { discovery.terminate(); throw VPNError.authenticationTimeout }
        let snapshot = try readSnapshot(from: paths.status)
        if snapshot.state == "failed" { throw VPNError.helperFailure(snapshot.message) }
        return snapshot.groups
    }

    func connect(request: CiscoAuthenticationRequest) async throws -> TunnelStatus {
        guard process?.isRunning != true else {
            return TunnelStatus(state: .connecting, message: "VPN connection is already starting", attemptID: request.attemptID)
        }
        let paths = try createSession(mode: "connect", gateway: request.gateway, request: request)
        let elevated = Process()
        elevated.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let command = "exec \(shellQuote(paths.helper.path)) \(shellQuote(paths.request.path))"
        elevated.arguments = ["-e", "do shell script \(appleScriptLiteral(command)) with administrator privileges"]
        do { try elevated.run() } catch { try? fileManager.removeItem(at: paths.directory); throw error }
        process = elevated
        sessionDirectory = paths.directory
        statusFile = paths.status
        otpFile = paths.otp
        attemptID = request.attemptID
        return TunnelStatus(state: .authenticating, message: "Contacting VPN gateway", attemptID: request.attemptID)
    }

    func submitOTP(_ value: String) async throws {
        guard let otpFile, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VPNError.otpNotRequested }
        try Data(value.utf8).write(to: otpFile, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: otpFile.path)
    }

    func disconnect() async throws -> TunnelStatus {
        if let process, process.isRunning {
            process.interrupt()
            if let pid = privilegedPID() {
                let stop = Process()
                stop.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                stop.arguments = ["-e", "do shell script \(appleScriptLiteral("/bin/kill -INT \(pid)")) with administrator privileges"]
                try stop.run()
            }
        }
        cleanUp()
        return .disconnected
    }

    func currentStatus() async throws -> TunnelStatus {
        guard let attemptID, let statusFile else { return .disconnected }
        guard let snapshot = try? readSnapshot(from: statusFile) else {
            return process?.isRunning == true
                ? TunnelStatus(state: .connecting, message: "Waiting for macOS authorization", attemptID: attemptID)
                : .disconnected
        }
        switch snapshot.state {
        case "connected": return TunnelStatus(state: .connected, message: snapshot.message, attemptID: attemptID)
        case "otpRequired": return TunnelStatus(state: .otpRequired, message: snapshot.message, attemptID: attemptID)
        case "authenticating": return TunnelStatus(state: .authenticating, message: snapshot.message, attemptID: attemptID)
        case "authenticationFailed": throw AuthenticationFailure(message: snapshot.message)
        case "failed": throw VPNError.helperFailure(snapshot.message)
        case "disconnected": cleanUp(); return .disconnected
        default: return TunnelStatus(state: .connecting, message: snapshot.message, attemptID: attemptID)
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
        return HelperSnapshot(state: dictionary["state"] as? String ?? "failed", message: dictionary["message"] as? String ?? "VPN helper failed", groups: groups)
    }

    private func wait(for process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !process.isRunning
    }

    private func privilegedPID() -> Int? {
        guard let sessionDirectory else { return nil }
        let url = sessionDirectory.appending(path: "pid")
        return (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func cleanUp() {
        process = nil; attemptID = nil; statusFile = nil; otpFile = nil
        if let sessionDirectory { try? fileManager.removeItem(at: sessionDirectory) }
        sessionDirectory = nil
    }

    private func shellQuote(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'" }
    private func appleScriptLiteral(_ value: String) -> String { "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }
}

private struct SessionPaths { let directory: URL; let helper: URL; let request: URL; let status: URL; let otp: URL; let pid: URL }
private struct HelperSnapshot { let state: String; let message: String; let groups: [VPNGroup] }
