import Foundation

enum URLSessionFactory {
    /// Builds a URLSession configured for the project's UniFi TLS requirements.
    static func makeSession(allowSelfSigned: Bool) -> URLSession {
        if allowSelfSigned {
            return URLSession(
                configuration: .default,
                delegate: SelfSignedDelegate.shared,
                delegateQueue: nil
            )
        }
        return URLSession.shared
    }
}

private final class SelfSignedDelegate: NSObject, URLSessionDelegate {
    static let shared = SelfSignedDelegate()

    /// Applies the self-signed-certificate policy to each URLSession challenge.
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust
        {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
