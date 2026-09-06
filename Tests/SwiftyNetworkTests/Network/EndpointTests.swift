import Foundation
import Testing

@testable import SwiftyNetwork

@Test("NetworkEndpoint builds URLRequest - basic")
func testEndpointBasic() throws {
    struct E: NetworkEndpoint {
        let baseURL = "https://api.test.com"
        var path: String { "/v1/items" }
        var method: HTTPMethod { .get }
    }

    let req = try E().makeURLRequest()
    #expect(req.url?.absoluteString == "https://api.test.com/v1/items")
    #expect(req.httpMethod == "GET")
}

@Test("NetworkEndpoint includes query items")
func testEndpointQueryItems() throws {
    struct E: NetworkEndpoint {
        let baseURL = "https://api.test.com"
        var path: String { "/search" }
        var method: HTTPMethod { .get }
        var queryItems: [URLQueryItem]? {
            [URLQueryItem(name: "q", value: "swift"), URLQueryItem(name: "lang", value: "en")]
        }
    }

    let req = try E().makeURLRequest()
    let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
    let items = comps?.queryItems ?? []
    #expect(items.contains(where: { $0.name == "q" && $0.value == "swift" }))
    #expect(items.contains(where: { $0.name == "lang" && $0.value == "en" }))
}

@Test("NetworkEndpoint sets headers, body and authorization")
func testEndpointHeadersBodyAuth() throws {
    struct E: NetworkEndpoint {
        let baseURL = "https://api.test.com"
        var path: String { "/upload" }
        var method: HTTPMethod { .post }
        var headers: [String: String]? { ["X-Test": "value"] }
        var authorization: AuthorizationType { .bearer(token: "abc123") }
        var body: Data? { "hello".data(using: .utf8) }
    }

    let req = try E().makeURLRequest()
    #expect(req.value(forHTTPHeaderField: "X-Test") == "value")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer abc123")
    #expect(String(data: req.httpBody ?? Data(), encoding: .utf8) == "hello")
    #expect(req.httpMethod == "POST")
}

@Test("NetworkEndpoint appends base path and endpoint path correctly")
func testEndpointPathAppending() throws {
    struct E: NetworkEndpoint {
        // base URL with existing path
        let baseURL = "https://api.test.com/base"
        var path: String { "/sub" }
        var method: HTTPMethod { .get }
    }

    let req = try E().makeURLRequest()
    #expect(req.url?.absoluteString == "https://api.test.com/base/sub")
}

@Test("NetworkEndpoint trims a trailing slash from the base URL")
func testEndpointTrimsTrailingSlash() throws {
    struct E: NetworkEndpoint {
        let baseURL = "https://api.test.com/base/"
        var path: String { "/sub" }
        var method: HTTPMethod { .get }
    }

    let req = try E().makeURLRequest()
    #expect(req.url?.absoluteString == "https://api.test.com/base/sub")
}

@Test("NetworkEndpoint throws on invalid base URL")
func testEndpointInvalidBaseURL() throws {
    struct E: NetworkEndpoint {
        let baseURL = "not a url"
        var path: String { "/x" }
        var method: HTTPMethod { .get }
    }

    #expect(throws: NetworkError.self) {
        try E().makeURLRequest()
    }
}

@Test("Endpoint normalizes repeated leading slashes without changing the host")
func testEndpointRepeatedLeadingSlashes() throws {
    let url = try EndpointURLBuilder.url(
        baseURL: "https://api.example.com/base///", path: "///items", queryItems: nil)
    #expect(url.absoluteString == "https://api.example.com/base/items")
}
