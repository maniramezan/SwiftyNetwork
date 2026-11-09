import Foundation
import SwiftyNetworkTesting
import Testing

@testable import SwiftyNetwork

@Suite("MutationRequest Tests")
struct MutationRequestTests {

    @Test("Captures fields from an existing endpoint, but never its authorization")
    func capturesEndpointFields() {
        struct LikeEndpoint: NetworkEndpoint {
            let baseURL = "https://api.test.com"
            var path: String { "/videos/42/like" }
            var method: HTTPMethod { .post }
            var headers: [String: String]? { ["X-Trace": "abc"] }
            var authorization: AuthorizationType { .bearer(token: "token123") }
        }

        let request = MutationRequest(endpoint: LikeEndpoint())

        #expect(request.baseURL == "https://api.test.com")
        #expect(request.path == "/videos/42/like")
        #expect(request.method == .post)
        #expect(request.headers == ["X-Trace": "abc"])
        #expect(request.authorization == .none)
    }

    @Test("Encodable body init adds a Content-Type header when missing")
    func encodableBodyAddsContentType() throws {
        struct UpdateEndpoint: NetworkEndpoint {
            let baseURL = "https://api.test.com"
            var path: String { "/profile" }
            var method: HTTPMethod { .patch }
        }
        struct Body: Encodable { let name: String }

        let request = try MutationRequest(endpoint: UpdateEndpoint(), encodableBody: Body(name: "Ada"))

        #expect(request.headers?["Content-Type"] == "application/json")
        let decoded = try JSONDecoder().decode([String: String].self, from: #require(request.body))
        #expect(decoded["name"] == "Ada")
    }

    @Test("Encodable body init preserves an existing Content-Type header")
    func encodableBodyPreservesExistingContentType() throws {
        struct UpdateEndpoint: NetworkEndpoint {
            let baseURL = "https://api.test.com"
            var path: String { "/profile" }
            var method: HTTPMethod { .patch }
            var headers: [String: String]? { ["Content-Type": "application/merge-patch+json"] }
        }
        struct Body: Encodable { let name: String }

        let request = try MutationRequest(endpoint: UpdateEndpoint(), encodableBody: Body(name: "Ada"))

        #expect(request.headers?["Content-Type"] == "application/merge-patch+json")
    }

    @Test("Round-trips through JSON with query items, headers, and body")
    func roundTripsThroughJSON() throws {
        let original = MutationRequest(
            baseURL: "https://api.test.com",
            path: "/videos/42/like",
            method: .post,
            queryItems: [URLQueryItem(name: "source", value: "detail")],
            headers: ["X-Trace": "abc"],
            body: Data("{\"liked\":true}".utf8)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MutationRequest.self, from: data)

        #expect(decoded == original)
    }

    @Test("Encodes a schema version and no authorization")
    func encodesVersionWithoutAuthorization() throws {
        let request = MutationRequest(baseURL: "https://api.test.com", path: "/x", method: .post)

        let json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )

        #expect(json["version"] as? Int == MutationRequest.version)
        #expect(json["authorization"] == nil)
    }

    @Test("Decodes a 1.x payload without a version and ignores its persisted authorization")
    func decodesLegacyPayload() throws {
        let legacy = Data(
            #"""
            {"baseURL":"https://api.test.com","path":"/x","method":"POST",
             "authorization":{"kind":"bearer","token":"stale"}}
            """#.utf8
        )

        let decoded = try JSONDecoder().decode(MutationRequest.self, from: legacy)

        #expect(decoded == MutationRequest(baseURL: "https://api.test.com", path: "/x", method: .post))
        #expect(decoded.authorization == .none)
    }

    @Test("Rejects a payload from a newer schema version")
    func rejectsNewerVersion() {
        let future = Data(#"{"version":2,"baseURL":"https://api.test.com","path":"/x","method":"POST"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MutationRequest.self, from: future)
        }
    }

    @Test("A replayed mutation is authorized by the client's provider, not by a captured token")
    func replayUsesProviderAuthorization() async throws {
        struct LikeEndpoint: NetworkEndpoint {
            let baseURL = "https://api.test.com"
            var path: String { "/like" }
            var method: HTTPMethod { .post }
            var queryItems: [URLQueryItem]? { [URLQueryItem(name: "test-id", value: "mutation-auth")] }
            var authorization: AuthorizationType { .bearer(token: "captured-at-enqueue") }
        }
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        stub.setResponses([.status(204)], for: "mutation-auth")
        let provider = TestAuthorizationProvider(current: .bearer(token: "current"), refreshResult: false)
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(session: stub.session, authorizationProvider: provider)
        )
        let persisted = try JSONEncoder().encode(MutationRequest(endpoint: LikeEndpoint()))

        try await client.request(JSONDecoder().decode(MutationRequest.self, from: persisted))

        #expect(stub.getLastRequestHeaders(for: "mutation-auth")?["Authorization"] == "Bearer current")
    }

    @Test("Produces a valid URLRequest via NetworkEndpoint conformance")
    func producesValidURLRequest() throws {
        let request = MutationRequest(baseURL: "https://api.test.com", path: "/videos/42/like", method: .post)

        let urlRequest = try request.makeURLRequest()

        #expect(urlRequest.url?.absoluteString == "https://api.test.com/videos/42/like")
        #expect(urlRequest.httpMethod == "POST")
    }
}
