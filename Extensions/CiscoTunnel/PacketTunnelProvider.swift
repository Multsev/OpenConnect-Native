import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var session: OpenConnectSession?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let providerConfiguration = protocolConfiguration as? NETunnelProviderProtocol,
              let configuration = TunnelConfiguration(
            persistent: providerConfiguration.providerConfiguration,
            launchOptions: options
        ) else {
            completionHandler(TunnelProviderError.missingCredentials)
            return
        }

        let session = OpenConnectSession(configuration: configuration)
        self.session = session
        session.start(
            packetFlow: packetFlow,
            configureNetwork: { [weak self] (settings: NEPacketTunnelNetworkSettings, ready: @escaping (NSError?) -> Void) in
                self?.setTunnelNetworkSettings(settings) { error in
                    ready(error as NSError?)
                    completionHandler(error)
                }
            },
            failed: { [weak self] error in
                self?.cancelTunnelWithError(error)
            }
        )
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        session?.stop()
        session = nil
        completionHandler()
    }
}

enum TunnelProviderError: LocalizedError {
    case missingCredentials

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "CiscoConnect did not receive the credentials for this connection attempt."
        }
    }
}
