import Testing
@testable import SwiftyNetwork

@Test("Endpoint builds URLRequest - basic")
func testEndpointBasic() throws {
    struct E: Endpoint {
        let baseURL = "https://api.test.com"
        var path: String { "/v1/items" }
        var method: HTTPMethod { .get }
        var queryItems: [URLQueryItem]? { nil }
        var headers: [String : String]? { nil }
        var authorization: AuthorizationType { .none }
        var body: Data? { nil }
    }

    let req = try E().makeURLRequest()
    #expect(req.url?.absoluteString == "https://api.test.com/v1/items")
    #expect(req.httpMethod == "GET")
}


@Test("Endpoint includes query items")
func testEndpointQueryItems() throws {
    struct E: Endpoint {
        let baseURL = "https://api.test.com"
        var path: String { "/search" }
        var method: HTTPMethod { .get }
        var queryItems: [URLQueryItem]? { [URLQueryItem(name: "q", value: "swift"), URLQueryItem(name: "lang", value: "en")] }
        var headers: [String : String]? { nil }
        var authorization: AuthorizationType { .none }
        var body: Data? { nil }
    }

    let req = try E().makeURLRequest()
    let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
    let items = comps?.queryItems ?? []
    #expect(items.contains(where: { $0.name == "q" && $0.value == "swift" }))
    #expect(items.contains(where: { $0.name == "lang" && $0.value == "en" }))
}


@Test("Endpoint sets headers, body and authorization")
func testEndpointHeadersBodyAuth() throws {
    struct E: Endpoint {
        let baseURL = "https://api.test.com"
        var path: String { "/upload" }
        var method: HTTPMethod { .post }
        var queryItems: [URLQueryItem]? { nil }
        var headers: [String : String]? { ["X-Test": "value"] }
        var authorization: AuthorizationType { .bearer(token: "abc123") }
        var body: Data? { "hello".data(using: .utf8) }
    }

    let req = try E().makeURLRequest()
    #expect(req.value(forHTTPHeaderField: "X-Test") == "value")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer abc123")
    #expect(String(data: req.httpBody ?? Data(), encoding: .utf8) == "hello")
    #expect(req.httpMethod == "POST")
}


@Test("Endpoint appends base path and endpoint path correctly")
func testEndpointPathAppending() throws {
    struct E: Endpoint {
        // base URL with existing path
        let baseURL = "https://api.test.com/base"
        var path: String { "/sub" }
        var method: HTTPMethod { .get }
        var queryItems: [URLQueryItem]? { nil }
        var headers: [String : String]? { nil }
        var authorization: AuthorizationType { .none }
        var body: Data? { nil }
    }

    let req = try E().makeURLRequest()
    #expect(req.url?.absoluteString == "https://api.test.com/base/sub")
}


@Test("Endpoint throws on invalid base URL")
func testEndpointInvalidBaseURL() throws {
    struct E: Endpoint {
        let baseURL = "not a url"
        var path: String { "/x" }
        var method: HTTPMethod { .get }
        var queryItems: [URLQueryItem]? { nil }
        var headers: [String : String]? { nil }
        var authorization: AuthorizationType { .none }
        var body: Data? { nil }
    }

    do {
        _ = try E().makeURLRequest()
        #expect(false)
    } catch is URLError {
        #expect(true)
    }
}
