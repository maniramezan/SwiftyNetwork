import CryptoKit
import Foundation
import Security

/// SSL pinning rules used by ``NetworkClient`` sessions.
///
/// Pinning is only applied to hosts listed in ``policies``. Unlisted hosts use
/// normal `URLSession` server-trust handling.
public struct SSLPinningConfiguration: Sendable, Equatable {
    /// A certificate or public-key pin accepted for a pinned host.
    public enum Pin: Sendable, Hashable {
        /// Pins the DER-encoded certificate bytes exactly.
        case certificate(Data)

        /// Pins the SHA-256 hash of the DER-encoded certificate bytes.
        case certificateSHA256(Data)

        /// Pins the SHA-256 hash of the public key bytes exported by Security.
        case publicKeySHA256(Data)

        /// Creates a certificate SHA-256 pin from a Base64-encoded 32-byte hash.
        ///
        /// - Parameter value: Base64-encoded SHA-256 hash data.
        /// - Returns: A pin when the value decodes to exactly 32 bytes; otherwise `nil`.
        public static func certificateSHA256(base64Encoded value: String) -> Self? {
            guard let data = Data(base64Encoded: value), data.count == SSLPinningValidator.sha256ByteCount else {
                return nil
            }
            return .certificateSHA256(data)
        }

        /// Creates a public-key SHA-256 pin from a Base64-encoded 32-byte hash.
        ///
        /// - Parameter value: Base64-encoded SHA-256 hash data.
        /// - Returns: A pin when the value decodes to exactly 32 bytes; otherwise `nil`.
        public static func publicKeySHA256(base64Encoded value: String) -> Self? {
            guard let data = Data(base64Encoded: value), data.count == SSLPinningValidator.sha256ByteCount else {
                return nil
            }
            return .publicKeySHA256(data)
        }
    }

    /// Pinning policy for one host.
    public struct HostPolicy: Sendable, Equatable {
        /// Pins accepted for this host.
        public var pins: Set<Pin>

        /// Whether this policy also applies to subdomains of its configured host.
        public var includesSubdomains: Bool

        /// Whether the server trust must pass the platform trust store before pins are checked.
        ///
        /// Keep this enabled unless you intentionally pin self-signed certificates or a private PKI.
        public var requiresDefaultTrustValidation: Bool

        /// Creates a host pinning policy.
        ///
        /// - Parameters:
        ///   - pins: Pins accepted for this host. Empty pin sets never match.
        ///   - includesSubdomains: Whether subdomains should inherit this policy. Defaults to `false`.
        ///   - requiresDefaultTrustValidation: Whether platform trust validation must pass first. Defaults to `true`.
        public init(
            pins: Set<Pin>,
            includesSubdomains: Bool = false,
            requiresDefaultTrustValidation: Bool = true
        ) {
            self.pins = pins
            self.includesSubdomains = includesSubdomains
            self.requiresDefaultTrustValidation = requiresDefaultTrustValidation
        }
    }

    /// Policies keyed by host name.
    public var policies: [String: HostPolicy]

    /// Creates SSL pinning configuration.
    ///
    /// - Parameter policies: Host policies keyed by exact host name, such as `"api.example.com"`.
    public init(policies: [String: HostPolicy]) {
        var normalized = [String: HostPolicy]()
        for (host, policy) in policies {
            normalized[Self.canonicalHost(host)] = policy
        }
        self.policies = normalized
    }

    /// Creates SSL pinning configuration with the same policy options for every host.
    ///
    /// - Parameters:
    ///   - pinnedHosts: Pins keyed by exact host name.
    ///   - includesSubdomains: Whether all configured hosts include their subdomains. Defaults to `false`.
    ///   - requiresDefaultTrustValidation: Whether platform trust validation must pass first. Defaults to `true`.
    public init(
        pinnedHosts: [String: Set<Pin>],
        includesSubdomains: Bool = false,
        requiresDefaultTrustValidation: Bool = true
    ) {
        self.init(
            policies: pinnedHosts.mapValues {
                HostPolicy(
                    pins: $0,
                    includesSubdomains: includesSubdomains,
                    requiresDefaultTrustValidation: requiresDefaultTrustValidation
                )
            }
        )
    }

    func policy(forHost host: String) -> HostPolicy? {
        let host = Self.canonicalHost(host)
        if let policy = policies[host] {
            return policy
        }

        for (policyHost, policy) in policies where policy.includesSubdomains {
            if host.hasSuffix("." + policyHost) {
                return policy
            }
        }
        return nil
    }

    private static func canonicalHost(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }
}

// MARK: - URLSession Delegate

final class SSLPinningURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let configuration: SSLPinningConfiguration

    /// Safety: `configuration` is immutable after initialization, and the delegate has no mutable state.
    init(configuration: SSLPinningConfiguration) {
        self.configuration = configuration
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        guard let policy = configuration.policy(forHost: host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            Logger.error("SSL pinning failed because server trust was unavailable", category: .security)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        if SSLPinningTrustEvaluator.evaluate(serverTrust, host: host, policy: policy) {
            Logger.info("SSL pinning validation succeeded", category: .security)
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            Logger.error("SSL pinning validation failed", category: .security)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - Trust Evaluation

enum SSLPinningTrustEvaluator {
    static func evaluate(
        _ trust: SecTrust,
        host: String,
        policy: SSLPinningConfiguration.HostPolicy
    ) -> Bool {
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))

        if policy.requiresDefaultTrustValidation {
            var trustError: CFError?
            guard SecTrustEvaluateWithError(trust, &trustError) else {
                if let trustError {
                    Logger.error("Default trust validation failed", error: trustError, category: .security)
                } else {
                    Logger.error("Default trust validation failed", category: .security)
                }
                return false
            }
        }

        let certificateChain = certificates(from: trust)
        let certificates = certificateChain.map { SecCertificateCopyData($0) as Data }
        let publicKeys = publicKeyData(from: certificateChain)
        return SSLPinningValidator.matches(pins: policy.pins, certificateData: certificates, publicKeyData: publicKeys)
    }

    private static func certificates(from trust: SecTrust) -> [SecCertificate] {
        guard let certificateChain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            return []
        }
        return certificateChain
    }

    private static func publicKeyData(from certificates: [SecCertificate]) -> [Data] {
        var keys = [Data]()
        keys.reserveCapacity(certificates.count)

        for certificate in certificates {
            guard let publicKey = SecCertificateCopyKey(certificate) else {
                continue
            }

            var copyError: Unmanaged<CFError>?
            guard let keyData = SecKeyCopyExternalRepresentation(publicKey, &copyError) as Data? else {
                if let error = copyError?.takeRetainedValue() {
                    Logger.error("Failed to export public key for SSL pinning", error: error, category: .security)
                }
                continue
            }
            keys.append(keyData)
        }
        return keys
    }
}

// MARK: - Pin Matching

enum SSLPinningValidator {
    static let sha256ByteCount = 32

    static func matches(
        pins: Set<SSLPinningConfiguration.Pin>,
        certificateData: [Data],
        publicKeyData: [Data]
    ) -> Bool {
        guard !pins.isEmpty else { return false }

        let certificateHashes = Set(certificateData.map(sha256Hash(of:)))
        let publicKeyHashes = Set(publicKeyData.map(sha256Hash(of:)))

        for pin in pins {
            switch pin {
            case .certificate(let pinnedCertificate):
                if certificateData.contains(pinnedCertificate) {
                    return true
                }
            case .certificateSHA256(let pinnedHash):
                if certificateHashes.contains(pinnedHash) {
                    return true
                }
            case .publicKeySHA256(let pinnedHash):
                if publicKeyHashes.contains(pinnedHash) {
                    return true
                }
            }
        }
        return false
    }

    static func sha256Hash(of data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}
