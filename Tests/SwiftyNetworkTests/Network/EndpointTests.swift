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

@Test("NetworkEndpoint preserves base URL query items when appending endpoint query items")
func testEndpointKeepsBaseURLQueryItems() throws {
    struct E: NetworkEndpoint {
        let baseURL = "https://api.test.com/search?source=home"
        var path: String { "" }
        var method: HTTPMethod { .get }
        var queryItems: [URLQueryItem]? {
            [URLQueryItem(name: "q", value: "swift"), URLQueryItem(name: "lang", value: "en")]
        }
    }

    let req = try E().makeURLRequest()
    let comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)
    let items = comps?.queryItems ?? []
    #expect(items.contains(where: { $0.name == "source" && $0.value == "home" }))
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

@Test("Endpoint request options override cache policy and timeout defaults")
func testEndpointRequestOptions() throws {
    struct E: NetworkEndpoint {
        let baseURL = "https://api.test.com"
        let path = "/balance"
        let method: HTTPMethod = .post
        let operationName: String? = "balance.refresh"
        let timeout: Duration? = .seconds(12)
        let cachePolicy: URLRequest.CachePolicy? = .reloadIgnoringLocalCacheData
        let isIdempotent = true
    }

    let request = try E().makeURLRequest()

    #expect(request.timeoutInterval == 12)
    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    #expect(E().operationName == "balance.refresh")
    #expect(E().isIdempotent)
}

@Test("Endpoint normalizes repeated leading slashes without changing the host")
func testEndpointRepeatedLeadingSlashes() throws {
    let url = try EndpointURLBuilder.url(
        baseURL: "https://api.example.com/base///", path: "///items", queryItems: nil)
    #expect(url.absoluteString == "https://api.example.com/base/items")
}

@Test("A complete URL in baseURL keeps its percent-encoded query exactly")
func testEndpointPreservesPresignedQuery() throws {
    let presigned =
        "https://bucket.s3.amazonaws.com/v.mp4?X-Amz-Credential=AKIA%2F20250101%2Fus-east-1&X-Amz-Signature=ab%2Bcd"
    let unchanged = try EndpointURLBuilder.url(baseURL: presigned, path: "", queryItems: nil)
    #expect(unchanged.absoluteString == presigned)

    let appended = try EndpointURLBuilder.url(
        baseURL: presigned, path: "", queryItems: [URLQueryItem(name: "range", value: "0-100")])
    #expect(appended.absoluteString == presigned + "&range=0-100")

    let emptyExisting = try EndpointURLBuilder.url(
        baseURL: "https://api.example.com/items?", path: "", queryItems: [URLQueryItem(name: "page", value: "2")])
    #expect(emptyExisting.absoluteString == "https://api.example.com/items?page=2")
}

@Test("Endpoint normalization preserves empty paths and collapses slash-only paths")
func testEndpointEmptyAndSlashOnlyPaths() throws {
    let empty = try EndpointURLBuilder.url(
        baseURL: "https://api.example.com/base///", path: "", queryItems: nil)
    #expect(empty.absoluteString == "https://api.example.com/base")
    let slashes = try EndpointURLBuilder.url(
        baseURL: "https://api.example.com/base///", path: "///", queryItems: nil)
    #expect(slashes.absoluteString == "https://api.example.com/base/")
}
