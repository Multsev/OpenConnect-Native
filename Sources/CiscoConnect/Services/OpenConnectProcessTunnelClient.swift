import Foundation

/// Runs the OpenConnect executable packaged inside CiscoConnect.
///
/// A packet VPN changes system routing and must run with administrator
/// privileges. macOS owns that authorization dialog; the app never receives or
/// stores the administrator password. VPN credentials are supplied through a
/// short-lived 0600 standard-input file, not process arguments.
@MainActor
final class OpenConnectProcessTunnelClient: TunnelClient {
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private var process: Process?
    private var pidFile: URL?
    private var logFile: URL?
    private var attemptID: UUID?

    init(fileManager: FileManager = .default, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    func connect(request: CiscoAuthenticationRequest) async throws -> TunnelStatus {
        guard process == nil else {
            return TunnelStatus(state: .connecting, message: "VPN connection is already starting", attemptID: request.attemptID)
        }
        let runtime = try runtimePaths()
        let token = request.attemptID.uuidString
        let credentials = temporaryDirectory.appending(path: "CiscoConnect-\(token).credentials")
        let pid = temporaryDirectory.appending(path: "CiscoConnect-\(token).pid")
        let log = temporaryDirectory.appending(path: "CiscoConnect-\(token).log")
        try writeCredentials(request: request, to: credentials)
        try Data().write(to: log, options: .atomic)

        // Open the descriptor, erase the credentials file, then replace the root
        // shell with OpenConnect. The secret never appears in argv or remains on disk.
        let command = privilegedCommand(executable: runtime.executable, script: runtime.script, request: request, credentialsFile: credentials, pidFile: pid, logFile: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(appleScriptLiteral(command)) with administrator privileges"]
        do {
            try process.run()
        } catch {
            try? fileManager.removeItem(at: credentials)
            throw error
        }
        self.process = process
        pidFile = pid
        logFile = log
        attemptID = request.attemptID
        return TunnelStatus(state: .connecting, message: "Approve macOS authorization to start OpenConnect", attemptID: request.attemptID)
    }

    func disconnect() async throws -> TunnelStatus {
        guard let pidFile, let pidText = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            process?.terminate()
            cleanUpFiles()
            return .disconnected
        }
        let stop = Process()
        stop.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        stop.arguments = ["-e", "do shell script \(appleScriptLiteral("/bin/kill -INT \(pid)")) with administrator privileges"]
        try stop.run()
        stop.waitUntilExit()
        cleanUpFiles()
        return .disconnected
    }

    func currentStatus() async throws -> TunnelStatus {
        guard let attemptID else { return .disconnected }
        let log = logFile.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        if log.localizedCaseInsensitiveContains("authentication failed") || log.localizedCaseInsensitiveContains("login failed") {
            throw AuthenticationFailure(message: "Cisco gateway rejected the supplied credentials.")
        }
        if log.localizedCaseInsensitiveContains("connected as") || log.localizedCaseInsensitiveContains("established dtls") || log.localizedCaseInsensitiveContains("esp tunnel established") {
            return TunnelStatus(state: .connected, message: "VPN connected", attemptID: attemptID)
        }
        if process?.isRunning == true { return TunnelStatus(state: .connecting, message: "Connecting to Cisco gateway", attemptID: attemptID) }
        if !log.isEmpty { return TunnelStatus(state: .failed, message: lastUsefulLogLine(log), attemptID: attemptID) }
        return .disconnected
    }

    private func runtimePaths() throws -> (executable: URL, script: URL) {
        let resourceRoot = Bundle.main.resourceURL?.appending(path: "OpenConnect")
        let executable = resourceRoot?.appending(path: "bin/openconnect")
        let script = resourceRoot?.appending(path: "vpnc-script")
        if let executable, let script, fileManager.isExecutableFile(atPath: executable.path), fileManager.isExecutableFile(atPath: script.path) {
            return (executable, script)
        }
        let homebrewExecutable = URL(fileURLWithPath: "/opt/homebrew/bin/openconnect")
        let homebrewScript = URL(fileURLWithPath: "/opt/homebrew/etc/vpnc/vpnc-script")
        guard fileManager.isExecutableFile(atPath: homebrewExecutable.path), fileManager.isExecutableFile(atPath: homebrewScript.path) else {
            throw VPNError.openConnectRuntimeMissing
        }
        return (homebrewExecutable, homebrewScript)
    }

    private func writeCredentials(request: CiscoAuthenticationRequest, to url: URL) throws {
        var input = request.password
        if !request.otp.isEmpty { input += "\n\(request.otp)" }
        input += "\n"
        guard let data = input.data(using: .utf8) else { throw VPNError.invalidProfile("VPN credentials cannot be encoded.") }
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func privilegedCommand(executable: URL, script: URL, request: CiscoAuthenticationRequest, credentialsFile: URL, pidFile: URL, logFile: URL) -> String {
        var arguments = [shellQuote(executable.path), "--protocol=anyconnect", "--user=\(shellQuote(request.username))", "--passwd-on-stdin", "--script=\(shellQuote(script.path))"]
        if !request.group.isEmpty { arguments.append("--authgroup=\(shellQuote(request.group))") }
        arguments.append(shellQuote(request.gateway.absoluteString))
        return "exec 3<\(shellQuote(credentialsFile.path)); /bin/rm -f \(shellQuote(credentialsFile.path)); echo $$ > \(shellQuote(pidFile.path)); exec \(arguments.joined(separator: " ")) <&3 >> \(shellQuote(logFile.path)) 2>&1"
    }

    private func cleanUpFiles() {
        process?.terminate()
        process = nil
        [pidFile, logFile].compactMap { $0 }.forEach { try? fileManager.removeItem(at: $0) }
        pidFile = nil
        logFile = nil
        attemptID = nil
    }

    private func shellQuote(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'"))'" }
    private func appleScriptLiteral(_ value: String) -> String { "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }
    private func lastUsefulLogLine(_ log: String) -> String { log.split(whereSeparator: \.isNewline).last.map(String.init) ?? "OpenConnect stopped unexpectedly." }
}
