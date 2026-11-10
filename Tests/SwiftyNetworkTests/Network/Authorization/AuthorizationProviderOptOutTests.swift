import Foundation
import SwiftyNetworkTesting
import Testing

@testable import SwiftyNetwork

@Suite("Endpoints that opt out of the authorization provider", .serialized)
struct AuthorizationProviderOptOutTests {
    private struct Endpoint: NetworkEndpoint {
        let testID: String
        var usesProvider = false
        var authorization: AuthorizationType = .none
        var method: HTTPMethod = .get

        let baseURL = "https://api.test.com"
        var path: String { "/public" }
        var queryItems: [URLQueryItem]? { [URLQueryItem(name: "test-id", value: testID)] }
        var usesAuthorizationProvider: Bool { usesProvider }
    }

    private struct Token: Codable, Sendable {
        let token: String
    }

    /// Holds the client the refresh handler calls, which exists only after the provider does.
    ///
    /// `@unchecked Sendable`: `client` is assigned once, before any request is sent, and only
    /// read afterwards.
    private final class ClientSlot: @unchecked Sendable {
        var client: NetworkClient?
    }

    private func makeClient(stub: TestHTTPStub, provider: any AuthorizationProvider) -> NetworkClient {
        NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session,
                authorizationProvider: provider,
                authRefreshDelay: .zero
            )
        )
    }

    @Test("An opted-out endpoint is sent without the provider's credentials")
    func sendsWithoutProviderCredentials() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.status(204)], for: id)
        let provider = TestAuthorizationProvider(current: .bearer(token: "secret"), refreshResult: true)
        let client = makeClient(stub: stub, provider: provider)

        try await client.request(Endpoint(testID: id))

        #expect(stub.getLastRequestHeaders(for: id)?["Authorization"] == nil)
    }

    @Test("An opted-out endpoint still applies its own authorization")
    func appliesOwnAuthorization() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.status(204)], for: id)
        let provider = TestAuthorizationProvider(current: .bearer(token: "secret"), refreshResult: true)
        let client = makeClient(stub: stub, provider: provider)

        try await client.request(Endpoint(testID: id, authorization: .apiKey(key: "k")))

        let headers = stub.getLastRequestHeaders(for: id)
        #expect(headers?["X-API-Key"] == "k")
        #expect(headers?["Authorization"] == nil)
    }

    @Test("A 401 on an opted-out endpoint throws unauthorized without refreshing")
    func unauthorizedWithoutRefresh() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.status(401)], for: id)
        let provider = TestAuthorizationProvider(current: .bearer(token: "secret"), refreshResult: true)
        let client = makeClient(stub: stub, provider: provider)

        await #expect {
            try await client.request(Endpoint(testID: id))
        } throws: { error in
            (error as? NetworkError)?.classification == .unauthorized
        }
        #expect(await provider.refreshCallCount == 0)
    }

    @Test("The opt-out survives a request with an encoded body")
    func encodedBodyKeepsOptOut() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.status(204)], for: id)
        let provider = TestAuthorizationProvider(current: .bearer(token: "secret"), refreshResult: true)
        let client = makeClient(stub: stub, provider: provider)

        try await client.request(Endpoint(testID: id, method: .post), body: Token(token: "x"))

        #expect(stub.getLastRequestHeaders(for: id)?["Authorization"] == nil)
    }

    @Test("A refresh handler can call the same client through an opted-out refresh endpoint")
    func refreshThroughSameClient() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let apiID = UUID().uuidString
        let refreshID = UUID().uuidString
        stub.setResponses([.status(401), .success(Data("{}".utf8))], for: apiID)
        stub.setResponses([.success(Data(#"{"token":"new"}"#.utf8))], for: refreshID)
        let slot = ClientSlot()
        let provider = OAuthAuthorizationProvider(initialAccessToken: "old") {
            let client = try #require(slot.client)
            return try await client.request(Endpoint(testID: refreshID, method: .post), responseType: Token.self)
                .token
        }
        let client = makeClient(stub: stub, provider: provider)
        slot.client = client

        try await client.request(makeEndpointWithTestId(apiID))

        #expect(stub.getLastRequestHeaders(for: apiID)?["Authorization"] == "Bearer new")
        #expect(stub.getLastRequestHeaders(for: refreshID)?["Authorization"] == nil)
    }

    @Test(
        "A refresh handler whose request needs a refresh fails instead of waiting on itself",
        .timeLimit(.minutes(1))
    )
    func nestedRefreshFails() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let apiID = UUID().uuidString
        let refreshID = UUID().uuidString
        stub.setResponses([.status(401)], for: apiID)
        stub.setResponses([.status(401)], for: refreshID)
        let slot = ClientSlot()
        let provider = OAuthAuthorizationProvider(initialAccessToken: "old") {
            let client = try #require(slot.client)
            return try await client.request(
                Endpoint(testID: refreshID, usesProvider: true, method: .post),
                responseType: Token.self
            ).token
        }
        let client = makeClient(stub: stub, provider: provider)
        slot.client = client

        await #expect {
            try await client.request(makeEndpointWithTestId(apiID))
        } throws: { error in
            guard case .authorizationRefreshFailed(let outer) = error as? NetworkError,
                case .authorizationRefreshFailed(let inner) = outer as? NetworkError
            else { return false }
            return inner is OAuthAuthorizationProvider.ReentrantRefreshError
        }
        #expect(await provider.currentAuthorization() == .bearer(token: "old"))
    }

    @Test("A 2xx with a plain-text body succeeds when the response is ignored")
    func plainTextBodyIsIgnored() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.success(Data("OK".utf8))], for: id)
        let client = NetworkClient(configuration: NetworkClientConfiguration(session: stub.session))

        let response = try await client.response(for: makeEndpointWithTestId(id))

        #expect(response.body == Data("OK".utf8))
    }
}
