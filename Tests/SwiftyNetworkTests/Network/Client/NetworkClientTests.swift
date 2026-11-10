import Foundation
import TestCommons
import Testing

@testable import SwiftyNetwork

@Test("NetworkClient conforms to APIClient")
func testNetworkClientConformsToAPIClient() {
    let client: APIClient = NetworkClient.shared
    #expect(client is NetworkClient)
}

@Suite("NetworkClient Integration Tests", .serialized)
struct NetworkClientIntegrationTests {
    @Test("NetworkClient decodes response and counts requests")
    func testNetworkClientDecodesResponseAndCountsRequests() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let user = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        let data = try JSONEncoder().encode(user)
        let testId = "decode-success"
        stub.setResponses(
            [.success(data)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        let response = try await client.request(endpoint, responseType: TestUser.self)

        #expect(response == user)
        #expect(stub.requests.count == 1)
    }

    @Test("NetworkClient applies authorization provider when endpoint has none")
    func testNetworkClientAppliesAuthorizationProvider() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "token-123"),
            refreshResult: false
        )
        let configuration = NetworkClientConfiguration(session: session, authorizationProvider: provider)
        let client = NetworkClient(configuration: configuration)
        let testId = "auth-provider"
        let payload = try JSONEncoder().encode(TestUser(id: "2", name: "Lin", email: "lin@example.com"))
        stub.setResponses(
            [.success(payload)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        _ = try await client.request(endpoint, responseType: TestUser.self)

        let headers = stub.getLastRequestHeaders(for: testId)
        #expect(headers?["Authorization"] == "Bearer token-123")
    }

    @Test("NetworkClient uses endpoint authorization over provider")
    func testNetworkClientUsesEndpointAuthorization() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        struct AuthEndpoint: NetworkEndpoint {
            let baseURL = "https://api.test.com"
            let authorization: AuthorizationType = .basicEncoded(credential: "basic-456")
            var path: String { "/auth" }
            var method: HTTPMethod { .get }
            var queryItems: [URLQueryItem]? { [URLQueryItem(name: "test-id", value: "endpoint-auth")] }
        }

        let session = stub.session
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "should-not-use"),
            refreshResult: false
        )
        let configuration = NetworkClientConfiguration(session: session, authorizationProvider: provider)
        let client = NetworkClient(configuration: configuration)
        let payload = try JSONEncoder().encode(TestUser(id: "3", name: "Kai", email: "kai@example.com"))
        stub.setResponses(
            [.success(payload)],
            for: "endpoint-auth"
        )

        _ = try await client.request(AuthEndpoint(), responseType: TestUser.self)
        let headers = stub.getLastRequestHeaders(for: "endpoint-auth")
        #expect(headers?["Authorization"] == "Basic basic-456")
    }

    @Test("NetworkClient refreshes authorization on 401 and retries")
    func testNetworkClientRefreshesOnUnauthorized() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "expired"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "fresh")
        )
        let configuration = NetworkClientConfiguration(
            session: session,
            authorizationProvider: provider,
            maxAuthRefreshAttempts: 2,
            authRefreshDelay: .zero
        )
        let client = NetworkClient(configuration: configuration)
        let user = TestUser(id: "4", name: "Mo", email: "mo@example.com")
        let data = try JSONEncoder().encode(user)
        let testId = "auth-refresh"
        stub.setResponses(
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
        #expect(await provider.rejectedAuthorizations == [.bearer(token: "expired")])
        #expect(stub.requests.count == 2)
    }

    @Test("NetworkClient reports authorization refresh failure")
    func testNetworkClientRefreshFailure() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
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
        stub.setResponses(
            [.status(401)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)

        await #expect {
            try await client.request(endpoint, responseType: TestUser.self)
        } throws: { error in
            guard let networkError = error as? NetworkError,
                case .authorizationRefreshFailed(let underlying) = networkError
            else { return false }
            return underlying is TestAuthorizationProvider.RefreshFailed
        }
    }

    @Test("NetworkClient maps http status to NetworkError")
    func testNetworkClientMapsStatusToError() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "status-map"
        stub.setResponses(
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
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "decode-fail"
        stub.setResponses(
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
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "empty-response"
        stub.setResponses(
            [.status(204)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        let response = try await client.request(endpoint, responseType: EmptyResponse.self)

        #expect(response == EmptyResponse())
    }

    @Test("NetworkClient no-body request supports successful empty responses")
    func testNetworkClientNoBodyRequestSupportsEmptyResponse() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "no-body-empty-response"
        stub.setResponses(
            [.status(204), .status(204), .status(204)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)

        try await client.request(endpoint)
        let httpResponse = try await client.response(for: endpoint)
        #expect(httpResponse.statusCode == 204)
        #expect(httpResponse.body.isEmpty)

        let bodyResponse = try await client.response(for: endpoint, body: ["key": "value"])
        #expect(bodyResponse.statusCode == 204)
    }

    @Test("NetworkClient maps URL errors")
    func testNetworkClientMapsURLError() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "url-error"
        stub.setResponses(
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
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "encode-body"
        let responseUser = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        let data = try JSONEncoder().encode(responseUser)
        stub.setResponses(
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
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "encode-body-content-type"
        let responseUser = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        let data = try JSONEncoder().encode(responseUser)
        stub.setResponses([.success(data)], for: testId)

        struct PostEndpoint: NetworkEndpoint {
            let testId: String
            let baseURL = "https://api.test.com"
            var path: String { "/users" }
            var method: HTTPMethod { .post }
            var queryItems: [URLQueryItem]? { [URLQueryItem(name: "test-id", value: testId)] }
        }

        let bodyPayload = TestUser(id: "new", name: "New", email: "new@example.com")
        _ = try await client.request(PostEndpoint(testId: testId), body: bodyPayload, responseType: TestUser.self)

        let headers = stub.getLastRequestHeaders(for: testId)
        #expect(contentType(in: headers) == "application/json")
    }

    @Test("NetworkClient preserves endpoint Content-Type for encoded bodies")
    func testNetworkClientPreservesEndpointContentType() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "encode-body-custom-content-type"
        let responseUser = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        let data = try JSONEncoder().encode(responseUser)
        stub.setResponses([.success(data)], for: testId)

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

        let headers = stub.getLastRequestHeaders(for: testId)
        #expect(contentType(in: headers) == "application/vnd.api+json")
    }

    /// Looks up the Content-Type header case-insensitively in captured request headers.
    private func contentType(in headers: [String: String]?) -> String? {
        headers?.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
    }

    @Test("NetworkClient throws encodingFailed for non-encodable body")
    func testNetworkClientEncodingFailure() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
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
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "status-403"
        stub.setResponses([.status(403)], for: testId)

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
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "status-408"
        stub.setResponses([.status(408)], for: testId)

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
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "status-500"
        stub.setResponses([.status(500)], for: testId)

        let endpoint = makeEndpointWithTestId(testId)
        await #expect {
            try await client.request(endpoint, responseType: TestUser.self)
        } throws: { error in
            guard let networkError = error as? NetworkError,
                case .serverError(let response) = networkError
            else { return false }
            return response.statusCode == 500
        }
    }

    @Test("NetworkClient maps notConnectedToInternet URL error")
    func testNetworkClientMapsNoInternet() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "no-internet"
        stub.setResponses(
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

    @Test("NetworkClient maps unreachable hosts to serverUnreachable")
    func testNetworkClientMapsUnreachableHosts() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "unrecognized-url-error"
        stub.setResponses(
            [.failure(URLError(.cannotFindHost))],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        await #expect {
            try await client.request(endpoint, responseType: TestUser.self)
        } throws: { error in
            guard let networkError = error as? NetworkError,
                case .serverUnreachable(let underlying) = networkError
            else { return false }
            return underlying.code == .cannotFindHost
        }
    }

    @Test("NetworkClient maps non-URLError transport failures to underlying")
    func testNetworkClientMapsNonURLErrorToUnderlying() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        struct CustomTransportError: Error {}

        let session = stub.session
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "custom-transport-error"
        stub.setResponses(
            [.failure(CustomTransportError())],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        await #expect {
            try await client.request(endpoint, responseType: TestUser.self)
        } throws: { error in
            guard let networkError = error as? NetworkError,
                case .underlying = networkError
            else { return false }
            return true
        }
    }

    @Test("NetworkClient emits debug logs when LogLevel.current is debug")
    func testNetworkClientDebugLogging() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let previousLevel = LogLevel.current
        LogLevel.current = .debug
        defer { LogLevel.current = previousLevel }
        #expect(LogLevel.current == .debug)
        let session = stub.session
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "debug-logging"
        let user = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        let data = try JSONEncoder().encode(user)
        stub.setResponses([.success(data)], for: testId)

        let response = try await client.request(makeEndpointWithTestId(testId), responseType: TestUser.self)

        #expect(response == user)
    }

    // MARK: - Retry Delay Tests

    @Test("NetworkClient authRefreshDelay delays before retry on 401")
    func testNetworkClientRetryDelayOnUnauthorized() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "expired"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "fresh")
        )
        let authRefreshDelay: Duration = .milliseconds(200)
        let configuration = NetworkClientConfiguration(
            session: session,
            authorizationProvider: provider,
            maxAuthRefreshAttempts: 1,
            authRefreshDelay: authRefreshDelay
        )
        let client = NetworkClient(configuration: configuration)
        let user = TestUser(id: "delay", name: "Delay", email: "delay@example.com")
        let data = try JSONEncoder().encode(user)
        let testId = "retry-delay"
        stub.setResponses(
            [.status(401), .success(data)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        let start = ContinuousClock().now
        let response = try await client.request(endpoint, responseType: TestUser.self)
        let elapsed = ContinuousClock().now - start

        #expect(response == user)
        // The delay should be at least authRefreshDelay (with some tolerance)
        #expect(elapsed >= .milliseconds(150))
    }

    @Test("NetworkClient authRefreshDelay of zero does not add delay")
    func testNetworkClientZeroRetryDelay() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "expired"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "fresh")
        )
        let configuration = NetworkClientConfiguration(
            session: session,
            authorizationProvider: provider,
            maxAuthRefreshAttempts: 1,
            authRefreshDelay: .zero
        )
        let client = NetworkClient(configuration: configuration)
        let user = TestUser(id: "nodelay", name: "NoDelay", email: "nodelay@example.com")
        let data = try JSONEncoder().encode(user)
        let testId = "zero-delay"
        let warmUpId = "zero-delay-warm-up"
        stub.setResponses([.success(data)], for: warmUpId)
        stub.setResponses(
            [.status(401), .success(data)],
            for: testId
        )

        // Pay the one-off session and simulator start-up cost before timing, so the
        // measurement below reflects only the refresh-and-retry path.
        _ = try await client.request(makeEndpointWithTestId(warmUpId), responseType: TestUser.self)

        let endpoint = makeEndpointWithTestId(testId)
        let start = ContinuousClock().now
        let response = try await client.request(endpoint, responseType: TestUser.self)
        let elapsed = ContinuousClock().now - start

        #expect(response == user)
        // A generous ceiling: shared CI simulators can stall for seconds, so this only
        // guards against an unexpectedly long wait rather than asserting a tight bound.
        #expect(elapsed < .seconds(5))
    }

    // MARK: - Auth Retry Exhaustion

    @Test("NetworkClient throws unauthorized when max retries exhausted")
    func testNetworkClientMaxRetriesExhausted() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let session = stub.session
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "expired"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "still-expired")
        )
        let configuration = NetworkClientConfiguration(
            session: session,
            authorizationProvider: provider,
            maxAuthRefreshAttempts: 1,
            authRefreshDelay: .zero
        )
        let client = NetworkClient(configuration: configuration)
        let testId = "max-retries"
        // Both responses are 401 — refresh succeeds but token still rejected
        stub.setResponses(
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
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        struct AuthEndpoint: NetworkEndpoint {
            let testId: String
            let baseURL = "https://api.test.com"
            var path: String { "/auth" }
            var method: HTTPMethod { .get }
            var queryItems: [URLQueryItem]? { [URLQueryItem(name: "test-id", value: testId)] }
            var authorization: AuthorizationType { .bearer(token: "endpoint-token") }
        }

        let session = stub.session
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "provider-token"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "fresh-provider-token")
        )
        let configuration = NetworkClientConfiguration(
            session: session,
            authorizationProvider: provider,
            maxAuthRefreshAttempts: 1,
            authRefreshDelay: .zero
        )
        let client = NetworkClient(configuration: configuration)
        let testId = "endpoint-auth-401"
        stub.setResponses(
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
}
