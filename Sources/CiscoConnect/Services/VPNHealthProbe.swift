import Foundation

/// An isolated, credential-free probe. Any HTTP response proves reachability;
/// redirects are not followed and response bodies are never downloaded.
final class VPNHealthProbe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static func check(_ url: URL) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        let delegate = VPNHealthProbe()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await session.data(for: request)
            return response is HTTPURLResponse
        } catch { return false }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct VPNHealthPolicy {
    private var failures = 0
    var isUnavailable: Bool { failures >= 2 }
    mutating func record(reachable: Bool) {
        failures = reachable ? 0 : min(2, failures + 1)
    }
}
