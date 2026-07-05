import Foundation
import Testing

@testable import SwiftyNetwork

@Test("NetworkClient conforms to APIClient")
func testNetworkClientConformsToAPIClient() {
    let client: APIClient = NetworkClient.shared
    #expect(client is NetworkClient)
}

@Suite("NetworkClient Integration Tests")
struct NetworkClientIntegrationTests {
    @Test("NetworkClient decodes response and counts requests")
    func testNetworkClientDecodesResponseAndCountsRequests() async throws {
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let user = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        let data = try JSONEncoder().encode(user)
        let testId = "decode-success"
        TestURLProtocol.setResponses(
            [.success(data)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        let response = try await client.request(endpoint, responseType: TestUser.self)

        #expect(response == user)
        let count = await client.attemptCount()
        #expect(count == 1)
    }

    @Test("NetworkClient applies authorization provider when endpoint has none")
    func testNetworkClientAppliesAuthorizationProvider() async throws {
        let session = makeTestSession()
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "token-123"),
            refreshResult: false
        )
        let configuration = NetworkClientConfiguration(session: session, authorizationProvider: provider)
        let client = NetworkClient(configuration: configuration)
        let testId = "auth-provider"
        let payload = try JSONEncoder().encode(TestUser(id: "2", name: "Lin", email: "lin@example.com"))
        TestURLProtocol.setResponses(
            [.success(payload)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        _ = try await client.request(endpoint, responseType: TestUser.self)

        let headers = TestURLProtocol.getLastRequestHeaders(for: testId)
        #expect(headers?["Authorization"] == "Bearer token-123")
    }

    @Test("NetworkClient uses endpoint authorization over provider")
    func testNetworkClientUsesEndpointAuthorization() async throws {
        struct AuthEndpoint: NetworkEndpoint {
            let baseURL = "https://api.test.com"
            let authorization: AuthorizationType = .basicEncoded(credential: "basic-456")
            var path: String { "/auth" }
            var method: HTTPMethod { .get }
            var queryItems: [URLQueryItem]? { [URLQueryItem(name: "test-id", value: "endpoint-auth")] }
        }

        let session = makeTestSession()
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "should-not-use"),
            refreshResult: false
        )
        let configuration = NetworkClientConfiguration(session: session, authorizationProvider: provider)
        let client = NetworkClient(configuration: configuration)
        let payload = try JSONEncoder().encode(TestUser(id: "3", name: "Kai", email: "kai@example.com"))
        TestURLProtocol.setResponses(
            [.success(payload)],
            for: "endpoint-auth"
        )

        _ = try await client.request(AuthEndpoint(), responseType: TestUser.self)
        let headers = TestURLProtocol.getLastRequestHeaders(for: "endpoint-auth")
        #expect(headers?["Authorization"] == "Basic basic-456")
    }

    @Test("NetworkClient refreshes authorization on 401 and retries")
    func testNetworkClientRefreshesOnUnauthorized() async throws {
        let session = makeTestSession()
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "expired"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "fresh")
        )
        let configuration = NetworkClientConfiguration(
            session: session,
            authorizationProvider: provider,
            maxAuthRefreshAttempts: 2,
            retryDelay: 0
        )
        let client = NetworkClient(configuration: configuration)
        let user = TestUser(id: "4", name: "Mo", email: "mo@example.com")
        let data = try JSONEncoder().encode(user)
        let testId = "auth-refresh"
        TestURLProtocol.setResponses(
            [
                .status(401),
                .success(data),
            ],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        let response = try await client.request(endpoint, responseType: TestUser.self)

        #expect(response == user)
        let refreshCalls = await provider.refreshCallCount
        #expect(refreshCalls == 1)
        let count = await client.attemptCount()
        #expect(count == 2)
    }

    @Test("NetworkClient reports authorization refresh failure")
    func testNetworkClientRefreshFailure() async throws {
        let session = makeTestSession()
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "expired"),
            refreshResult: false
        )
        let configuration = NetworkClientConfiguration(
            session: session,
            authorizationProvider: provider,
            maxAuthRefreshAttempts: 1
        )
        let client = NetworkClient(configuration: configuration)
        let testId = "auth-refresh-fail"
        TestURLProtocol.setResponses(
            [.status(401)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)

        await #expect {
            try await client.request(endpoint, responseType: TestUser.self)
        } throws: { error in
            guard let networkError = error as? NetworkError,
                case .authorizationRefreshFailed = networkError
            else { return false }
            return true
        }
    }

    @Test("NetworkClient maps http status to NetworkError")
    func testNetworkClientMapsStatusToError() async throws {
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "status-map"
        TestURLProtocol.setResponses(
            [.status(404)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        await #expect {
            try await client.request(endpoint, responseType: TestUser.self)
        } throws: { error in
            guard let networkError = error as? NetworkError,
                case .notFound = networkError
            else { return false }
            return true
        }
    }

    @Test("NetworkClient maps decoding failures")
    func testNetworkClientDecodingFailure() async throws {
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "decode-fail"
        TestURLProtocol.setResponses(
            [.success(Data("invalid".utf8))],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        await #expect {
            try await client.request(endpoint, responseType: TestUser.self)
        } throws: { error in
            guard let networkError = error as? NetworkError,
                case .decodingFailed = networkError
            else { return false }
            return true
        }
    }

    @Test("NetworkClient supports successful empty responses")
    func testNetworkClientSupportsEmptyResponse() async throws {
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "empty-response"
        TestURLProtocol.setResponses(
            [.status(204)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        let response = try await client.request(endpoint, responseType: EmptyResponse.self)

        #expect(response == EmptyResponse())
    }

    @Test("NetworkClient no-body request supports successful empty responses")
    func testNetworkClientNoBodyRequestSupportsEmptyResponse() async throws {
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "no-body-empty-response"
        TestURLProtocol.setResponses(
            [.status(204)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)

        try await client.request(endpoint)
    }

    @Test("NetworkClient maps URL errors")
    func testNetworkClientMapsURLError() async throws {
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "url-error"
        TestURLProtocol.setResponses(
            [.failure(URLError(.timedOut))],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        await #expect {
            try await client.request(endpoint, responseType: TestUser.self)
        } throws: { error in
            guard let networkError = error as? NetworkError,
                case .timeout = networkError
            else { return false }
            return true
        }
    }

    // MARK: - Encoder Convenience Tests

    @Test("NetworkClient encodes Encodable body and sends request")
    func testNetworkClientEncodesBody() async throws {
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "encode-body"
        let responseUser = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        let data = try JSONEncoder().encode(responseUser)
        TestURLProtocol.setResponses(
            [.success(data)],
            for: testId
        )

        struct PostEndpoint: NetworkEndpoint {
            let testId: String
            let baseURL = "https://api.test.com"
            var path: String { "/users" }
            var method: HTTPMethod { .post }
            var queryItems: [URLQueryItem]? { [URLQueryItem(name: "test-id", value: testId)] }
        }

        let bodyPayload = TestUser(id: "new", name: "New", email: "new@example.com")
        let response = try await client.request(
            PostEndpoint(testId: testId),
            body: bodyPayload,
            responseType: TestUser.self
        )

        #expect(response == responseUser)
    }

    @Test("NetworkClient adds Content-Type application/json for encoded bodies")
    func testNetworkClientAddsJSONContentType() async throws {
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "encode-body-content-type"
        let responseUser = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        let data = try JSONEncoder().encode(responseUser)
        TestURLProtocol.setResponses([.success(data)], for: testId)

        struct PostEndpoint: NetworkEndpoint {
            let testId: String
            let baseURL = "https://api.test.com"
            var path: String { "/users" }
            var method: HTTPMethod { .post }
            var queryItems: [URLQueryItem]? { [URLQueryItem(name: "test-id", value: testId)] }
        }

        let bodyPayload = TestUser(id: "new", name: "New", email: "new@example.com")
        _ = try await client.request(PostEndpoint(testId: testId), body: bodyPayload, responseType: TestUser.self)

        let headers = TestURLProtocol.getLastRequestHeaders(for: testId)
        #expect(contentType(in: headers) == "application/json")
    }

    @Test("NetworkClient preserves endpoint Content-Type for encoded bodies")
    func testNetworkClientPreservesEndpointContentType() async throws {
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "encode-body-custom-content-type"
        let responseUser = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        let data = try JSONEncoder().encode(responseUser)
        TestURLProtocol.setResponses([.success(data)], for: testId)

        struct PostEndpoint: NetworkEndpoint {
            let testId: String
            let baseURL = "https://api.test.com"
            var path: String { "/users" }
            var method: HTTPMethod { .post }
            var queryItems: [URLQueryItem]? { [URLQueryItem(name: "test-id", value: testId)] }
            var headers: [String: String]? { ["Content-Type": "application/vnd.api+json"] }
        }

        let bodyPayload = TestUser(id: "new", name: "New", email: "new@example.com")
        _ = try await client.request(PostEndpoint(testId: testId), body: bodyPayload, responseType: TestUser.self)

        let headers = TestURLProtocol.getLastRequestHeaders(for: testId)
        #expect(contentType(in: headers) == "application/vnd.api+json")
    }

    /// Looks up the Content-Type header case-insensitively in captured request headers.
    private func contentType(in headers: [String: String]?) -> String? {
        headers?.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
    }

    @Test("NetworkClient throws encodingFailed for non-encodable body")
    func testNetworkClientEncodingFailure() async throws {
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)

        struct BadBody: Encodable, Sendable {
            func encode(to encoder: any Encoder) throws {
                throw EncodingError.invalidValue(
                    "bad",
                    EncodingError.Context(codingPath: [], debugDescription: "test failure")
                )
            }
        }

        await #expect {
            try await client.request(TestEndpoint(), body: BadBody(), responseType: TestUser.self)
        } throws: { error in
            guard let networkError = error as? NetworkError,
                case .encodingFailed = networkError
            else { return false }
            return true
        }
    }

    // MARK: - Additional Status Code Mapping Tests

    @Test("NetworkClient maps 403 to forbidden error")
    func testNetworkClientMaps403() async throws {
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "status-403"
        TestURLProtocol.setResponses([.status(403)], for: testId)

        let endpoint = makeEndpointWithTestId(testId)
        await #expect {
            try await client.request(endpoint, responseType: TestUser.self)
        } throws: { error in
            guard let networkError = error as? NetworkError,
                case .forbidden = networkError
            else { return false }
            return true
        }
    }

    @Test("NetworkClient maps 408 to timeout error")
    func testNetworkClientMaps408() async throws {
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "status-408"
        TestURLProtocol.setResponses([.status(408)], for: testId)

        let endpoint = makeEndpointWithTestId(testId)
        await #expect {
            try await client.request(endpoint, responseType: TestUser.self)
        } throws: { error in
            guard let networkError = error as? NetworkError,
                case .timeout = networkError
            else { return false }
            return true
        }
    }

    @Test("NetworkClient maps 500 to serverError")
    func testNetworkClientMaps500() async throws {
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "status-500"
        TestURLProtocol.setResponses([.status(500)], for: testId)

        let endpoint = makeEndpointWithTestId(testId)
        await #expect {
            try await client.request(endpoint, responseType: TestUser.self)
        } throws: { error in
            guard let networkError = error as? NetworkError,
                case .serverError(let code, _) = networkError
            else { return false }
            return code == 500
        }
    }

    @Test("NetworkClient maps notConnectedToInternet URL error")
    func testNetworkClientMapsNoInternet() async throws {
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "no-internet"
        TestURLProtocol.setResponses(
            [.failure(URLError(.notConnectedToInternet))],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        await #expect {
            try await client.request(endpoint, responseType: TestUser.self)
        } throws: { error in
            guard let networkError = error as? NetworkError,
                case .noInternetConnection = networkError
            else { return false }
            return true
        }
    }

    // MARK: - Retry Delay Tests

    @Test("NetworkClient retryDelay delays before retry on 401")
    func testNetworkClientRetryDelayOnUnauthorized() async throws {
        let session = makeTestSession()
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "expired"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "fresh")
        )
        let retryDelay: TimeInterval = 0.2
        let configuration = NetworkClientConfiguration(
            session: session,
            authorizationProvider: provider,
            maxAuthRefreshAttempts: 1,
            retryDelay: retryDelay
        )
        let client = NetworkClient(configuration: configuration)
        let user = TestUser(id: "delay", name: "Delay", email: "delay@example.com")
        let data = try JSONEncoder().encode(user)
        let testId = "retry-delay"
        TestURLProtocol.setResponses(
            [.status(401), .success(data)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        let start = ContinuousClock().now
        let response = try await client.request(endpoint, responseType: TestUser.self)
        let elapsed = ContinuousClock().now - start

        #expect(response == user)
        // The delay should be at least retryDelay (with some tolerance)
        #expect(elapsed >= .milliseconds(150))
    }

    @Test("NetworkClient retryDelay of zero does not add delay")
    func testNetworkClientZeroRetryDelay() async throws {
        let session = makeTestSession()
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "expired"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "fresh")
        )
        let configuration = NetworkClientConfiguration(
            session: session,
            authorizationProvider: provider,
            maxAuthRefreshAttempts: 1,
            retryDelay: 0
        )
        let client = NetworkClient(configuration: configuration)
        let user = TestUser(id: "nodelay", name: "NoDelay", email: "nodelay@example.com")
        let data = try JSONEncoder().encode(user)
        let testId = "zero-delay"
        TestURLProtocol.setResponses(
            [.status(401), .success(data)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        let start = ContinuousClock().now
        let response = try await client.request(endpoint, responseType: TestUser.self)
        let elapsed = ContinuousClock().now - start

        #expect(response == user)
        // Should complete quickly without artificial delay
        #expect(elapsed < .milliseconds(500))
    }

    // MARK: - Auth Retry Exhaustion

    @Test("NetworkClient throws unauthorized when max retries exhausted")
    func testNetworkClientMaxRetriesExhausted() async throws {
        let session = makeTestSession()
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "expired"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "still-expired")
        )
        let configuration = NetworkClientConfiguration(
            session: session,
            authorizationProvider: provider,
            maxAuthRefreshAttempts: 1,
            retryDelay: 0
        )
        let client = NetworkClient(configuration: configuration)
        let testId = "max-retries"
        // Both responses are 401 — refresh succeeds but token still rejected
        TestURLProtocol.setResponses(
            [.status(401), .status(401)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        await #expect {
            try await client.request(endpoint, responseType: TestUser.self)
        } throws: { error in
            guard let networkError = error as? NetworkError,
                case .unauthorized = networkError
            else { return false }
            return true
        }

        // Should have attempted refresh exactly once
        let refreshCalls = await provider.refreshCallCount
        #expect(refreshCalls == 1)
    }

    @Test("NetworkClient does not refresh provider when endpoint authorization was used")
    func testNetworkClientDoesNotRefreshProviderForEndpointAuthorization() async throws {
        struct AuthEndpoint: NetworkEndpoint {
            let testId: String
            let baseURL = "https://api.test.com"
            var path: String { "/auth" }
            var method: HTTPMethod { .get }
            var queryItems: [URLQueryItem]? { [URLQueryItem(name: "test-id", value: testId)] }
            var authorization: AuthorizationType { .bearer(token: "endpoint-token") }
        }

        let session = makeTestSession()
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "provider-token"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "fresh-provider-token")
        )
        let configuration = NetworkClientConfiguration(
            session: session,
            authorizationProvider: provider,
            maxAuthRefreshAttempts: 1,
            retryDelay: 0
        )
        let client = NetworkClient(configuration: configuration)
        let testId = "endpoint-auth-401"
        TestURLProtocol.setResponses(
            [.status(401)],
            for: testId
        )

        await #expect {
            try await client.request(AuthEndpoint(testId: testId), responseType: TestUser.self)
        } throws: { error in
            guard let networkError = error as? NetworkError,
                case .unauthorized = networkError
            else { return false }
            return true
        }

        let refreshCalls = await provider.refreshCallCount
        #expect(refreshCalls == 0)
    }

    @Test("NetworkClient keeps request configuration stable across awaits")
    func testNetworkClientUsesConfigurationSnapshot() async throws {
        let initialSession = makeTestSession()
        let replacementSession = makeTestSession()
        let configuration = NetworkClientConfiguration(session: initialSession)
        let client = NetworkClient(configuration: configuration)
        let user = TestUser(id: "snapshot", name: "Stable", email: "stable@example.com")
        let data = try JSONEncoder().encode(user)
        let testId = "configuration-snapshot"
        TestURLProtocol.setResponses(
            [.success(data, delay: 0.05)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        async let response = client.request(endpoint, responseType: TestUser.self)
        await Task.yield()
        await client.updateConfiguration(NetworkClientConfiguration(session: replacementSession))

        let fetched = try await response

        #expect(fetched == user)
    }
}
