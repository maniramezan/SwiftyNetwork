import Foundation
import Security
import Testing

@testable import SwiftyNetwork

/// A minimal, unused challenge sender required to construct a `URLAuthenticationChallenge` in tests.
private final class StubChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}

@Suite("SSL Pinning Configuration Tests")
struct SSLPinningConfigurationTests {
    /// A self-signed EC P-256 certificate for "pinning.test", generated with:
    /// ```
    /// openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    ///   -keyout key.pem -out cert.pem -days 300 -nodes \
    ///   -subj "/CN=pinning.test" \
    ///   -addext "subjectAltName=DNS:pinning.test" \
    ///   -addext "extendedKeyUsage=serverAuth" \
    ///   -addext "keyUsage=digitalSignature" \
    ///   -addext "basicConstraints=critical,CA:FALSE"
    /// openssl x509 -in cert.pem -outform der -out cert.der
    /// ```
    ///
    /// A SAN, a `serverAuth` EKU, and a short validity span are all required for
    /// `SecTrustEvaluateWithError` to accept this certificate under Apple's TLS
    /// server policy, even when it is installed as its own trust anchor. This
    /// fixture is valid until **2027-05-01**; if
    /// `testEvaluateSucceedsWithAnchoredCertificateAndMatchingPin` starts failing
    /// with "certificate is not standards compliant", regenerate it with the
    /// command above and update ``expectedSPKIHashBase64`` to match.
    private static let testCertificateBase64 = """
        MIIBvjCCAWOgAwIBAgIUXqdrokR3M4xnJzhi/scleoC1/0owCgYIKoZIzj0EAwIwFzEVMBMGA1UE\
        AwwMcGlubmluZy50ZXN0MB4XDTI2MDcwNTE4NDUxMFoXDTI3MDUwMTE4NDUxMFowFzEVMBMGA1UE\
        AwwMcGlubmluZy50ZXN0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEhWwTr8YJAOqsW9XjCog0\
        eBYJ4bYXyHpyzQVOBu4v3pBhfcwqofO8Yiru9sPXPxi2nIVHA4wWtEJZM+gwKz9JN6OBjDCBiTAd\
        BgNVHQ4EFgQUepzROJwU7AIEXHdnz2Ag/4PPDU8wHwYDVR0jBBgwFoAUepzROJwU7AIEXHdnz2Ag\
        /4PPDU8wFwYDVR0RBBAwDoIMcGlubmluZy50ZXN0MBMGA1UdJQQMMAoGCCsGAQUFBwMBMAsGA1Ud\
        DwQEAwIHgDAMBgNVHRMBAf8EAjAAMAoGCCqGSM49BAMCA0kAMEYCIQCZxE5jNDee4G9LfYAXq120\
        ZCbQz0DivUDyOLFg/XYUDgIhAM4r5dKy/fpFRzoBZKJmO5r6vb7q2zB4GmEHP81JDU7L
        """

    /// Cross-checked with the OpenSSL reference command for SPKI SHA-256 pins:
    /// ```
    /// openssl x509 -in cert.pem -pubkey -noout \
    ///   | openssl pkey -pubin -outform der \
    ///   | openssl dgst -sha256 -binary | base64
    /// ```
    private static let expectedSPKIHashBase64 = "GvWR9D5mIOkuQ77mmuK5PBsyQWRDwRFEYqEZeRGtNfg="

    private func makeTestCertificate() throws -> SecCertificate {
        let data = try #require(Data(base64Encoded: Self.testCertificateBase64))
        return try #require(SecCertificateCreateWithData(nil, data as CFData))
    }

    private func makeTrust(for certificate: SecCertificate, host: String) throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &trust)
        #expect(status == errSecSuccess)
        return try #require(trust)
    }

    @Test("Computed SPKI SHA-256 hash matches the OpenSSL reference value")
    func testSubjectPublicKeyInfoHashMatchesOpenSSLReference() throws {
        let certificate = try makeTestCertificate()
        let publicKey = try #require(SecCertificateCopyKey(certificate))
        let spki = try #require(SSLPinningTrustEvaluator.subjectPublicKeyInfo(for: publicKey))
        let hash = SSLPinningValidator.sha256Hash(of: spki)

        let expectedHash = try #require(Data(base64Encoded: Self.expectedSPKIHashBase64))
        #expect(hash == expectedHash)
    }

    @Test("Evaluate succeeds when the certificate is a trusted anchor and the pin matches")
    func testEvaluateSucceedsWithAnchoredCertificateAndMatchingPin() throws {
        let certificate = try makeTestCertificate()
        let trust = try makeTrust(for: certificate, host: "pinning.test")
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        let expectedHash = try #require(Data(base64Encoded: Self.expectedSPKIHashBase64))
        let policy = SSLPinningConfiguration.HostPolicy(
            pins: [.publicKeySHA256(expectedHash)],
            requiresDefaultTrustValidation: true
        )

        #expect(SSLPinningTrustEvaluator.evaluate(trust, host: "pinning.test", policy: policy))
    }

    @Test("Evaluate fails default trust validation for an unanchored self-signed certificate")
    func testEvaluateFailsDefaultTrustValidationWithoutAnchor() throws {
        let certificate = try makeTestCertificate()
        let trust = try makeTrust(for: certificate, host: "pinning.test")

        let expectedHash = try #require(Data(base64Encoded: Self.expectedSPKIHashBase64))
        let policy = SSLPinningConfiguration.HostPolicy(
            pins: [.publicKeySHA256(expectedHash)],
            requiresDefaultTrustValidation: true
        )

        #expect(!SSLPinningTrustEvaluator.evaluate(trust, host: "pinning.test", policy: policy))
    }

    @Test("Evaluate rejects a non-matching pin even when default trust validation is skipped")
    func testEvaluateRejectsMismatchedPinWithoutDefaultValidation() throws {
        let certificate = try makeTestCertificate()
        let trust = try makeTrust(for: certificate, host: "pinning.test")

        let wrongHash = SSLPinningValidator.sha256Hash(of: Data([1, 2, 3, 4]))
        let policy = SSLPinningConfiguration.HostPolicy(
            pins: [.publicKeySHA256(wrongHash)],
            requiresDefaultTrustValidation: false
        )

        #expect(!SSLPinningTrustEvaluator.evaluate(trust, host: "pinning.test", policy: policy))
    }

    @Test("Evaluate matches a real certificate chain's public key when default trust validation is skipped")
    func testEvaluateMatchesRealChainWithoutDefaultValidation() throws {
        let certificate = try makeTestCertificate()
        let trust = try makeTrust(for: certificate, host: "pinning.test")

        let expectedHash = try #require(Data(base64Encoded: Self.expectedSPKIHashBase64))
        let policy = SSLPinningConfiguration.HostPolicy(
            pins: [.publicKeySHA256(expectedHash)],
            requiresDefaultTrustValidation: false
        )

        #expect(SSLPinningTrustEvaluator.evaluate(trust, host: "pinning.test", policy: policy))
    }

    @Test("Delegate performs default handling for non server-trust authentication methods")
    func testDelegatePerformsDefaultHandlingForNonServerTrustMethod() async throws {
        let sender = StubChallengeSender()
        let protectionSpace = URLProtectionSpace(
            host: "pinning.test",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: sender
        )
        let pin = SSLPinningConfiguration.Pin.certificate(Data([1, 2, 3]))
        let configuration = SSLPinningConfiguration(pinnedHosts: ["pinning.test": [pin]])
        let delegate = SSLPinningURLSessionDelegate(configuration: configuration)

        let disposition = await withCheckedContinuation { continuation in
            delegate.urlSession(.shared, didReceive: challenge) { disposition, _ in
                continuation.resume(returning: disposition)
            }
        }

        #expect(disposition == .performDefaultHandling)
    }

    @Test("Delegate performs default handling for unpinned hosts")
    func testDelegatePerformsDefaultHandlingForUnpinnedHost() async throws {
        let sender = StubChallengeSender()
        let protectionSpace = URLProtectionSpace(
            host: "unpinned.test",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: sender
        )
        let pin = SSLPinningConfiguration.Pin.certificate(Data([1, 2, 3]))
        let configuration = SSLPinningConfiguration(pinnedHosts: ["pinning.test": [pin]])
        let delegate = SSLPinningURLSessionDelegate(configuration: configuration)

        let disposition = await withCheckedContinuation { continuation in
            delegate.urlSession(.shared, didReceive: challenge) { disposition, _ in
                continuation.resume(returning: disposition)
            }
        }

        #expect(disposition == .performDefaultHandling)
    }

    @Test("Delegate cancels the challenge when server trust is unavailable for a pinned host")
    func testDelegateCancelsWhenServerTrustUnavailable() async throws {
        let sender = StubChallengeSender()
        let protectionSpace = URLProtectionSpace(
            host: "pinning.test",
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: sender
        )
        let pin = SSLPinningConfiguration.Pin.certificate(Data([1, 2, 3]))
        let configuration = SSLPinningConfiguration(pinnedHosts: ["pinning.test": [pin]])
        let delegate = SSLPinningURLSessionDelegate(configuration: configuration)

        let disposition = await withCheckedContinuation { continuation in
            delegate.urlSession(.shared, didReceive: challenge) { disposition, _ in
                continuation.resume(returning: disposition)
            }
        }

        #expect(disposition == .cancelAuthenticationChallenge)
    }

    @Test("Base64 SHA-256 pin factories validate hash length")
    func testBase64PinFactoriesValidateHashLength() throws {
        let hash = Data(repeating: 7, count: 32)
        let encoded = hash.base64EncodedString()

        let certificatePin = try #require(SSLPinningConfiguration.Pin.certificateSHA256(base64Encoded: encoded))
        let publicKeyPin = try #require(SSLPinningConfiguration.Pin.publicKeySHA256(base64Encoded: encoded))

        #expect(certificatePin == .certificateSHA256(hash))
        #expect(publicKeyPin == .publicKeySHA256(hash))
        #expect(SSLPinningConfiguration.Pin.certificateSHA256(base64Encoded: "bad-base64") == nil)
        #expect(
            SSLPinningConfiguration.Pin.publicKeySHA256(base64Encoded: Data([1, 2, 3]).base64EncodedString()) == nil)
    }

    @Test("Policies normalize hosts and match exact hosts")
    func testPoliciesNormalizeHostsAndMatchExactHosts() throws {
        let pin = SSLPinningConfiguration.Pin.certificate(Data([1, 2, 3]))
        let policy = SSLPinningConfiguration.HostPolicy(pins: [pin])
        let configuration = SSLPinningConfiguration(policies: ["API.EXAMPLE.COM.": policy])

        let matchedPolicy = try #require(configuration.policy(forHost: "api.example.com"))

        #expect(matchedPolicy == policy)
        #expect(configuration.policy(forHost: "static.example.com") == nil)
    }

    @Test("Policies optionally match subdomains")
    func testPoliciesOptionallyMatchSubdomains() throws {
        let pin = SSLPinningConfiguration.Pin.certificate(Data([1, 2, 3]))
        let inheritedPolicy = SSLPinningConfiguration.HostPolicy(pins: [pin], includesSubdomains: true)
        let exactOnlyPolicy = SSLPinningConfiguration.HostPolicy(pins: [pin], includesSubdomains: false)
        let inheritedConfiguration = SSLPinningConfiguration(policies: ["example.com": inheritedPolicy])
        let exactOnlyConfiguration = SSLPinningConfiguration(policies: ["example.com": exactOnlyPolicy])

        #expect(inheritedConfiguration.policy(forHost: "api.example.com") == inheritedPolicy)
        #expect(inheritedConfiguration.policy(forHost: "badexample.com") == nil)
        #expect(exactOnlyConfiguration.policy(forHost: "api.example.com") == nil)
    }

    @Test("Validator matches certificate and hash pins")
    func testValidatorMatchesCertificateAndHashPins() {
        let certificate = Data([1, 2, 3, 4])
        let certificateHash = SSLPinningValidator.sha256Hash(of: certificate)
        let publicKey = Data([5, 6, 7, 8])
        let publicKeyHash = SSLPinningValidator.sha256Hash(of: publicKey)

        #expect(
            SSLPinningValidator.matches(
                pins: [.certificate(certificate)],
                certificateData: [certificate],
                publicKeyData: []
            )
        )
        #expect(
            SSLPinningValidator.matches(
                pins: [.certificateSHA256(certificateHash)],
                certificateData: [certificate],
                publicKeyData: []
            )
        )
        #expect(
            SSLPinningValidator.matches(
                pins: [.publicKeySHA256(publicKeyHash)],
                certificateData: [],
                publicKeyData: [publicKey]
            )
        )
    }

    @Test("Validator rejects empty and nonmatching pins")
    func testValidatorRejectsEmptyAndNonmatchingPins() {
        let certificate = Data([1, 2, 3, 4])
        let wrongHash = SSLPinningValidator.sha256Hash(of: Data([9, 9, 9, 9]))

        #expect(
            !SSLPinningValidator.matches(
                pins: [],
                certificateData: [certificate],
                publicKeyData: []
            )
        )
        #expect(
            !SSLPinningValidator.matches(
                pins: [.certificateSHA256(wrongHash)],
                certificateData: [certificate],
                publicKeyData: []
            )
        )
    }

    @Test("SPKI construction matches the standard SPKI encoding for EC P-256 and RSA 2048 keys")
    func testSubjectPublicKeyInfoMatchesStandardEncoding() throws {
        var error: Unmanaged<CFError>?

        let ecAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
        ]
        let ecPrivateKey = try #require(SecKeyCreateRandomKey(ecAttributes as CFDictionary, &error))
        let ecPublicKey = try #require(SecKeyCopyPublicKey(ecPrivateKey))
        let ecRawKey = try #require(SecKeyCopyExternalRepresentation(ecPublicKey, &error) as Data?)
        let ecSPKI = try #require(SSLPinningTrustEvaluator.subjectPublicKeyInfo(for: ecPublicKey))
        // Canonical SPKI prefix for an uncompressed P-256 public key (as used by TrustKit/HPKP).
        let ecHeader = Data([
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
        ])
        #expect(ecSPKI == ecHeader + ecRawKey)

        let rsaAttributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
        ]
        let rsaPrivateKey = try #require(SecKeyCreateRandomKey(rsaAttributes as CFDictionary, &error))
        let rsaPublicKey = try #require(SecKeyCopyPublicKey(rsaPrivateKey))
        let rsaRawKey = try #require(SecKeyCopyExternalRepresentation(rsaPublicKey, &error) as Data?)
        let rsaSPKI = try #require(SSLPinningTrustEvaluator.subjectPublicKeyInfo(for: rsaPublicKey))
        // Canonical SPKI prefix for a 2048-bit RSA public key (as used by TrustKit/HPKP).
        let rsaHeader = Data([
            0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
            0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00,
        ])
        #expect(rsaSPKI == rsaHeader + rsaRawKey)
    }

    @Test("SPKI construction matches the standard SPKI encoding for EC P-384 and P-521 keys")
    func testSubjectPublicKeyInfoMatchesStandardEncodingForLargerECCurves() throws {
        var error: Unmanaged<CFError>?

        let p384Attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 384,
        ]
        let p384PrivateKey = try #require(SecKeyCreateRandomKey(p384Attributes as CFDictionary, &error))
        let p384PublicKey = try #require(SecKeyCopyPublicKey(p384PrivateKey))
        let p384RawKey = try #require(SecKeyCopyExternalRepresentation(p384PublicKey, &error) as Data?)
        let p384SPKI = try #require(SSLPinningTrustEvaluator.subjectPublicKeyInfo(for: p384PublicKey))
        // Canonical SPKI prefix for an uncompressed P-384 public key, cross-checked against
        // `openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:secp384r1 | openssl pkey -pubout -outform der`.
        let p384Header = Data([
            0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
            0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00,
        ])
        #expect(p384SPKI == p384Header + p384RawKey)

        let p521Attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 521,
        ]
        let p521PrivateKey = try #require(SecKeyCreateRandomKey(p521Attributes as CFDictionary, &error))
        let p521PublicKey = try #require(SecKeyCopyPublicKey(p521PrivateKey))
        let p521RawKey = try #require(SecKeyCopyExternalRepresentation(p521PublicKey, &error) as Data?)
        let p521SPKI = try #require(SSLPinningTrustEvaluator.subjectPublicKeyInfo(for: p521PublicKey))
        // Canonical SPKI prefix for an uncompressed P-521 public key, cross-checked against
        // `openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:secp521r1 | openssl pkey -pubout -outform der`.
        let p521Header = Data([
            0x30, 0x81, 0x9b, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
            0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x23, 0x03, 0x81, 0x86, 0x00,
        ])
        #expect(p521SPKI == p521Header + p521RawKey)
    }

    @Test("Pinned session initializer preserves request configuration")
    func testPinnedSessionInitializerPreservesRequestConfiguration() async throws {
        let pin = SSLPinningConfiguration.Pin.certificate(Data([1, 2, 3]))
        let pinning = SSLPinningConfiguration(pinnedHosts: ["api.test.com": [pin]])
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [TestURLProtocol.self]
        let authorizationProvider = TestAuthorizationProvider(current: .apiKey(key: "key"), refreshResult: false)

        let configuration = NetworkClientConfiguration(
            sslPinning: pinning,
            sessionConfiguration: sessionConfiguration,
            authorizationProvider: authorizationProvider,
            maxAuthRefreshAttempts: -1,
            timeoutInterval: 12,
            retryDelay: 0,
            logLevel: .info
        )
        let client = NetworkClient(configuration: configuration)
        let user = TestUser(id: "ssl", name: "Pinned", email: "pin@example.com")
        let data = try JSONEncoder().encode(user)
        let testId = "ssl-pinning-unlisted-protocol"
        TestURLProtocol.setResponses([.success(data)], for: testId)

        let response = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)

        #expect(configuration.maxAuthRefreshAttempts == 0)
        #expect(configuration.timeoutInterval == 12)
        #expect(configuration.retryDelay == 0)
        #expect(configuration.logLevel == .info)
        #expect(response == user)
    }
}
