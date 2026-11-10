import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("TypedEndpoint Tests", .serialized)
struct TypedEndpointTests {
    private struct UserEndpoint: TypedEndpoint {
        typealias Response = TestUser

        let id: String
        let baseURL = "https://api.test.com"
        var path: String { "/users/\(id)" }
        let method: HTTPMethod = .get
        var queryItems: [URLQueryItem]? {
            [URLQueryItem(name: "test-id", value: "typed-endpoint")]
        }
    }

    @Test("APIClient.send decodes the response type declared by the endpoint")
    func sendsTypedEndpoint() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let user = TestUser(id: "42", name: "Ada", email: "ada@example.com")
        stub.setResponses([.success(try JSONEncoder().encode(user))], for: "typed-endpoint")
        let client = NetworkClient(configuration: NetworkClientConfiguration(session: stub.session))

        let result = try await client.send(UserEndpoint(id: "42"))

        #expect(result == user)
    }
}
