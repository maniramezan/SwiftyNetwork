import Foundation
import Testing

@testable @_spi(Testing) import SwiftyNetwork

@Suite("NetworkClient default headers")
struct NetworkClientDefaultHeadersTests {
    private struct HeaderEndpoint: NetworkEndpoint {
        let testId: String
        var headers: [String: String]?

        let baseURL = "https://api.test.com"
        let path = "/users/123"
        let method: HTTPMethod = .get
        var queryItems: [URLQueryItem]? { [URLQueryItem(name: "test-id", value: testId)] }
    }

    private func makeClient(stub: TestHTTPStub, provider: (any AuthorizationProvider)? = nil) -> NetworkClient {
        var configuration = NetworkClientConfiguration(session: stub.session, authorizationProvider: provider)
        configuration.defaultHeaders = [
            "Accept-Language": "en-GB", "X-App-Version": "4.2.0", "Authorization": "Default",
        ]
        return NetworkClient(configuration: configuration)
    }

    @Test("Default headers are sent, an endpoint's own header wins, and authorization is applied last")
    func appliesDefaultsUnderEndpointHeaders() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.success(Data())], for: id)
        let provider = TestAuthorizationProvider(current: .bearer(token: "t"), refreshResult: true)
        let client = makeClient(stub: stub, provider: provider)

        try await client.request(HeaderEndpoint(testId: id, headers: ["accept-language": "fa"]))

        let sent = try #require(stub.getLastRequestHeaders(for: id))
        #expect(sent["Accept-Language"] == "fa" || sent["accept-language"] == "fa")
        #expect(sent["X-App-Version"] == "4.2.0")
        #expect(sent["Authorization"] == "Bearer t")
    }

    @Test("A raw request sent with sendAuthorized gets the default headers it does not set")
    func appliesDefaultsToRawRequests() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let id = UUID().uuidString
        stub.setResponses([.success(Data())], for: id)
        let client = makeClient(stub: stub)
        var request = URLRequest(url: try #require(URL(string: "https://api.test.com/stream?test-id=\(id)")))
        request.setValue("fa", forHTTPHeaderField: "Accept-Language")

        _ = try await client.sendAuthorized(request) { request, session, delegate in
            try await session.data(for: request, delegate: delegate)
        }

        let sent = try #require(stub.getLastRequestHeaders(for: id))
        #expect(sent["Accept-Language"] == "fa")
        #expect(sent["X-App-Version"] == "4.2.0")
    }

    @Test("A configuration has no default headers unless set")
    func defaultsToNoHeaders() {
        #expect(NetworkClientConfiguration().defaultHeaders.isEmpty)
    }
}
