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

        /// Pins the SHA-256 hash of the DER-encoded `SubjectPublicKeyInfo` (SPKI) of the public key.
        ///
        /// This matches the industry-standard pin format used by HPKP and TrustKit.
        /// Generate a pin for a live server with:
        /// ```
        /// openssl s_client -connect api.example.com:443 < /dev/null 2>/dev/null \
        ///   | openssl x509 -pubkey -noout \
        ///   | openssl pkey -pubin -outform der \
        ///   | openssl dgst -sha256 -binary \
        ///   | base64
        /// ```
        /// RSA (2048/3072/4096-bit) and EC (P-256/P-384/P-521) keys are supported.
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
        /// The hash must be computed over the DER-encoded `SubjectPublicKeyInfo`;
        /// see ``publicKeySHA256(_:)`` for how to generate one.
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

            guard let spki = subjectPublicKeyInfo(for: publicKey) else {
                Logger.error(
                    "Failed to build SubjectPublicKeyInfo for SSL pinning; skipping key", category: .security)
                continue
            }
            keys.append(spki)
        }
        return keys
    }

    /// Builds the DER-encoded `SubjectPublicKeyInfo` for a public key so pin
    /// hashes match the industry-standard SPKI SHA-256 format.
    ///
    /// Security exports RSA keys as PKCS#1 and EC keys as raw points, so the
    /// ASN.1 algorithm identifier and BIT STRING framing must be rebuilt here.
    /// Returns `nil` for unsupported key types or curves.
    static func subjectPublicKeyInfo(for key: SecKey) -> Data? {
        var copyError: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(key, &copyError) as Data? else {
            if let error = copyError?.takeRetainedValue() {
                Logger.error("Failed to export public key for SSL pinning", error: error, category: .security)
            }
            return nil
        }

        guard let attributes = SecKeyCopyAttributes(key) as? [CFString: Any],
            let keyType = attributes[kSecAttrKeyType] as? String
        else {
            return nil
        }

        let algorithmIdentifier: Data
        if keyType == (kSecAttrKeyTypeRSA as String) {
            // SEQUENCE { OID 1.2.840.113549.1.1.1 (rsaEncryption), NULL }
            algorithmIdentifier = Data([
                0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
                0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00,
            ])
        } else if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            guard let keySizeInBits = attributes[kSecAttrKeySizeInBits] as? Int,
                let curveOID = ecCurveOID(forKeySizeInBits: keySizeInBits)
            else {
                return nil
            }
            // OID 1.2.840.10045.2.1 (ecPublicKey)
            let ecPublicKeyOID = Data([0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01])
            algorithmIdentifier = derSequence(ecPublicKeyOID + curveOID)
        } else {
            return nil
        }

        return derSequence(algorithmIdentifier + derBitString(keyData))
    }

    private static func ecCurveOID(forKeySizeInBits keySizeInBits: Int) -> Data? {
        switch keySizeInBits {
        case 256:
            // OID 1.2.840.10045.3.1.7 (prime256v1 / P-256)
            return Data([0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07])
        case 384:
            // OID 1.3.132.0.34 (secp384r1 / P-384)
            return Data([0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22])
        case 521:
            // OID 1.3.132.0.35 (secp521r1 / P-521)
            return Data([0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x23])
        default:
            return nil
        }
    }

    // MARK: - Minimal DER Encoding

    private static func derLength(_ length: Int) -> Data {
        guard length >= 128 else {
            return Data([UInt8(length)])
        }
        var bytes = [UInt8]()
        var value = length
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + bytes
    }

    private static func derSequence(_ content: Data) -> Data {
        Data([0x30]) + derLength(content.count) + content
    }

    private static func derBitString(_ content: Data) -> Data {
        // Leading 0x00 indicates no unused bits in the final byte.
        let padded = Data([0x00]) + content
        return Data([0x03]) + derLength(padded.count) + padded
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
