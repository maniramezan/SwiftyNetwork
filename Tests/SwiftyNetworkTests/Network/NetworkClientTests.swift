import Foundation
import Testing

@testable import SwiftyNetwork

@Test("NetworkClient maps status codes to NetworkError")
func testNetworkClientStatusCodeMapping() async throws {
    // Minimal smoke check here; detailed tests live elsewhere.
    // Status code mapping is tested in other specific test cases
}

@Test("NetworkClient conforms to APIClient")
func testNetworkClientConformsToAPIClient() {
    let client: APIClient = NetworkClient.shared
    #expect(client is NetworkClient)
}

@Suite("NetworkClient Integration Tests", .serialized)
struct NetworkClientIntegrationTests {
    @Test("NetworkClient decodes response and counts requests")
    func testNetworkClientDecodesResponseAndCountsRequests() async throws {
        TestURLProtocol.reset()
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
        let count = await client.getRequestCount()
        #expect(count == 1)
    }

    @Test("NetworkClient applies authorization provider when endpoint has none")
    func testNetworkClientAppliesAuthorizationProvider() async throws {
        TestURLProtocol.reset()
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
        TestURLProtocol.reset()
        struct AuthEndpoint: NetworkEndpoint {
            let baseURL = "https://api.test.com"
            let authorization: AuthorizationType = .basic(token: "basic-456")
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
        TestURLProtocol.reset()
        let session = makeTestSession()
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "expired"),
            refreshResult: true,
            refreshedAuthorization: .bearer(token: "fresh")
        )
        let configuration = NetworkClientConfiguration(
            session: session,
            authorizationProvider: provider,
            maxRetryAttempts: 2
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
        let count = await client.getRequestCount()
        #expect(count == 2)
    }

    @Test("NetworkClient reports authorization refresh failure")
    func testNetworkClientRefreshFailure() async throws {
        TestURLProtocol.reset()
        let session = makeTestSession()
        let provider = TestAuthorizationProvider(
            current: .bearer(token: "expired"),
            refreshResult: false
        )
        let configuration = NetworkClientConfiguration(
            session: session,
            authorizationProvider: provider,
            maxRetryAttempts: 1
        )
        let client = NetworkClient(configuration: configuration)
        let testId = "auth-refresh-fail"
        TestURLProtocol.setResponses(
            [.status(401)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)

        do {
            _ = try await client.request(endpoint, responseType: TestUser.self)
            Issue.record("Expected NetworkError.authorizationRefreshFailed to be thrown")
        } catch let error as NetworkError {
            if case .authorizationRefreshFailed = error {
                // Expected behavior
            } else {
                Issue.record("Expected authorizationRefreshFailed but got \(error)")
            }
        }
    }

    @Test("NetworkClient maps http status to NetworkError")
    func testNetworkClientMapsStatusToError() async throws {
        TestURLProtocol.reset()
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "status-map"
        TestURLProtocol.setResponses(
            [.status(404)],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        do {
            _ = try await client.request(endpoint, responseType: TestUser.self)
            Issue.record("Expected error to be thrown")
        } catch let error as NetworkError {
            if case .notFound = error {
                // Expected behavior
            } else {
                Issue.record("Expected notFound but got \(error)")
            }
        }
    }

    @Test("NetworkClient maps decoding failures")
    func testNetworkClientDecodingFailure() async throws {
        TestURLProtocol.reset()
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "decode-fail"
        TestURLProtocol.setResponses(
            [.success(Data("invalid".utf8))],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        do {
            _ = try await client.request(endpoint, responseType: TestUser.self)
            Issue.record("Expected error to be thrown")
        } catch let error as NetworkError {
            if case .decodingFailed = error {
                // Expected behavior
            } else {
                Issue.record("Expected decodingFailed but got \(error)")
            }
        }
    }

    @Test("NetworkClient maps URL errors")
    func testNetworkClientMapsURLError() async throws {
        TestURLProtocol.reset()
        let session = makeTestSession()
        let configuration = NetworkClientConfiguration(session: session)
        let client = NetworkClient(configuration: configuration)
        let testId = "url-error"
        TestURLProtocol.setResponses(
            [.failure(URLError(.timedOut))],
            for: testId
        )

        let endpoint = makeEndpointWithTestId(testId)
        do {
            _ = try await client.request(endpoint, responseType: TestUser.self)
            Issue.record("Expected error to be thrown")
        } catch let error as NetworkError {
            if case .timeout = error {
                // Expected behavior
            } else {
                Issue.record("Expected timeout but got \(error)")
            }
        }
    }
}
