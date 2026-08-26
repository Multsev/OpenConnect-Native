import Foundation

@MainActor
final class PrivilegedHelperInstaller {
    private static let installedVersionPath = "/Library/PrivilegedHelperTools/com.max.openconnectnative.runtime/version"

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func ensureInstalled(connection: PrivilegedHelperConnection) async throws {
        if installedVersion == bundledVersion {
            do {
                try await connection.ping()
                return
            } catch {
                // A stopped or stale daemon is repaired by the same one-time installer.
            }
        }

        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            throw VPNError.appMustBeInstalled
        }
        try await install()
        try await connection.ping()
    }

    var isInstalled: Bool {
        fileManager.fileExists(atPath: Self.installedVersionPath)
    }

    func uninstall() async throws {
        guard isInstalled else { return }
        guard let script = Bundle.main.url(forResource: "UninstallPrivilegedHelper", withExtension: "sh") else {
            throw VPNError.openConnectRuntimeMissing
        }
        do {
            try await runAsAdministrator(script: script, arguments: [])
        } catch {
            throw VPNError.helperRemovalFailed
        }
    }

    private var installedVersion: String? {
        try? String(contentsOfFile: Self.installedVersionPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var bundledVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }

    private func install() async throws {
        guard let script = Bundle.main.url(forResource: "InstallPrivilegedHelper", withExtension: "sh") else {
            throw VPNError.openConnectRuntimeMissing
        }
        do {
            try await runAsAdministrator(
                script: script,
                arguments: [Bundle.main.bundleURL.path, bundledVersion]
            )
        } catch {
            throw VPNError.helperInstallationFailed
        }
    }

    private func runAsAdministrator(script: URL, arguments: [String]) async throws {
        let command = ([script.path] + arguments)
            .map(shellQuote)
            .joined(separator: " ")
        let appleScript = "do shell script \(appleScriptLiteral(command)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: VPNError.helperFailure("Системная операция была отменена или завершилась ошибкой"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func appleScriptLiteral(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
