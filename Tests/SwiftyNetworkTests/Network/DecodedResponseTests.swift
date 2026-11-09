import Foundation
import SwiftyNetworkTesting
import Testing

@testable import SwiftyNetwork

@Suite("Successful response access")
struct DecodedResponseTests {
    private let user = TestUser(id: "1", name: "Ada", email: "ada@example.com")

    private func makeClient(_ stub: TestHTTPStub) -> NetworkClient {
        NetworkClient(configuration: NetworkClientConfiguration(session: stub.session))
    }

    @Test("response(for:responseType:) returns the decoded value with status, headers, and body")
    func responseCarriesHeaders() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let body = try JSONEncoder().encode(user)
        stub.setResponses(
            [.status(200, data: body, headers: ["ETag": "\"v1\"", "Link": "<https://api.test.com/p2>; rel=next"])],
            for: "etag"
        )

        let result = try await makeClient(stub).response(
            for: makeEndpointWithTestId("etag"),
            responseType: TestUser.self
        )

        #expect(result.value == user)
        #expect(result.response.statusCode == 200)
        #expect(result.response.header("etag") == "\"v1\"")
        #expect(result.response.header("Link") == "<https://api.test.com/p2>; rel=next")
        #expect(result.response.body == body)
    }

    @Test("Requesting Data returns the raw body without JSON decoding")
    func dataReturnsRawBody() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF])
        stub.setResponses([.success(png)], for: "raw")

        let data = try await makeClient(stub).request(makeEndpointWithTestId("raw"), responseType: Data.self)

        #expect(data == png)
    }

    @Test("An Encodable-body request exposes response headers such as Location")
    func bodyRequestExposesLocation() async throws {
        struct Draft: Encodable, Sendable { let title: String }
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        stub.setResponses([.status(201, headers: ["Location": "/posts/7"])], for: "create")

        let created = try await makeClient(stub).response(
            for: makeEndpointWithTestId("create", method: .post),
            body: Draft(title: "Hello"),
            responseType: EmptyResponse.self
        )

        #expect(created.response.statusCode == 201)
        #expect(created.response.header("Location") == "/posts/7")
    }

    @Test("MockAPIClient scripts headers with an http stub and returns raw Data for json stubs")
    func mockScriptsHeaders() async throws {
        let client = MockAPIClient()
        let body = try JSONEncoder().encode(user)
        let scripted = HTTPResponse(statusCode: 200, headers: ["ETag": "v2"], body: body)
        await client.stub(.get, "/users/1", with: .http(scripted))
        await client.stub(.get, "/avatar", with: .json(Data([1, 2, 3])))

        let result = try await client.response(for: MockEndpoint(path: "/users/1"), responseType: TestUser.self)
        let avatar = try await client.request(MockEndpoint(path: "/avatar"), responseType: Data.self)

        #expect(result.value == user)
        #expect(result.response.header("ETag") == "v2")
        #expect(avatar == Data([1, 2, 3]))
    }

    @Test("DecodedResponse is Equatable when its value is, comparing both value and response")
    func decodedResponseEquality() {
        let ok = HTTPResponse(statusCode: 200, headers: ["ETag": "v1"])
        let base = DecodedResponse(value: user, response: ok)

        #expect(base == DecodedResponse(value: user, response: ok))
        #expect(base != DecodedResponse(value: TestUser(id: "2", name: "Bo", email: "bo@example.com"), response: ok))
        #expect(base != DecodedResponse(value: user, response: HTTPResponse(statusCode: 201)))
    }

    private struct MockEndpoint: NetworkEndpoint {
        let baseURL = "https://api.test.com"
        let path: String
        var method: HTTPMethod { .get }
    }
}
