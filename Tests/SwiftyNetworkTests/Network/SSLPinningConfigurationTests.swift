import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("SSL Pinning Configuration Tests")
struct SSLPinningConfigurationTests {
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
