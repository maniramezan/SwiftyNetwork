import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("MutationRequest Tests")
struct MutationRequestTests {

    @Test("Captures fields from an existing endpoint")
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
        #expect(request.authorization == .bearer(token: "token123"))
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

    @Test("Round-trips through JSON, including authorization and query items")
    func roundTripsThroughJSON() throws {
        let original = MutationRequest(
            baseURL: "https://api.test.com",
            path: "/videos/42/like",
            method: .post,
            queryItems: [URLQueryItem(name: "source", value: "detail")],
            headers: ["X-Trace": "abc"],
            authorization: .bearer(token: "secret-token"),
            body: Data("{\"liked\":true}".utf8)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MutationRequest.self, from: data)

        #expect(decoded == original)
    }

    @Test("Round-trips every AuthorizationType case")
    func roundTripsAllAuthorizationCases() throws {
        let cases: [AuthorizationType] = [
            .none,
            .basic(username: "user", password: "pass"),
            .basicEncoded(credential: "dXNlcjpwYXNz"),
            .bearer(token: "token"),
            .apiKey(key: "key123", header: "X-API-Key"),
            .custom(header: "X-Custom", value: "value"),
        ]

        for authorization in cases {
            let request = MutationRequest(
                baseURL: "https://api.test.com", path: "/x", method: .get, authorization: authorization)
            let data = try JSONEncoder().encode(request)
            let decoded = try JSONDecoder().decode(MutationRequest.self, from: data)
            #expect(decoded.authorization == authorization)
        }
    }

    @Test("Produces a valid URLRequest via NetworkEndpoint conformance")
    func producesValidURLRequest() throws {
        let request = MutationRequest(baseURL: "https://api.test.com", path: "/videos/42/like", method: .post)

        let urlRequest = try request.makeURLRequest()

        #expect(urlRequest.url?.absoluteString == "https://api.test.com/videos/42/like")
        #expect(urlRequest.httpMethod == "POST")
    }
}
