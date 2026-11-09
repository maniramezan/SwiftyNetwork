import Foundation
import Testing

@testable import SwiftyNetwork

@Test("HTTPMethod raw values")
func testHTTPMethodRawValues() {
    #expect(HTTPMethod.get.rawValue == "GET")
    #expect(HTTPMethod.post.rawValue == "POST")
    #expect(HTTPMethod.put.rawValue == "PUT")
    #expect(HTTPMethod.delete.rawValue == "DELETE")
    #expect(HTTPMethod.patch.rawValue == "PATCH")
    #expect(HTTPMethod.head.rawValue == "HEAD")
    #expect(HTTPMethod.options.rawValue == "OPTIONS")
}

@Test("A custom method is sent exactly as given")
func testCustomHTTPMethod() throws {
    struct PropfindEndpoint: NetworkEndpoint {
        let baseURL = "https://dav.example.com"
        let path = "/files"
        let method: HTTPMethod = "PROPFIND"
    }

    let request = try PropfindEndpoint().makeURLRequest()

    #expect(request.httpMethod == "PROPFIND")
    #expect(HTTPMethod(rawValue: "PROPFIND") == "PROPFIND")
    #expect(HTTPMethod.get.description == "GET")
}

@Test("HTTPMethod encodes as a bare string, matching the 1.x enum")
func testHTTPMethodCodable() throws {
    let data = try JSONEncoder().encode([HTTPMethod.post, "PROPFIND"])

    #expect(String(decoding: data, as: UTF8.self) == #"["POST","PROPFIND"]"#)
    #expect(try JSONDecoder().decode([HTTPMethod].self, from: data) == [.post, "PROPFIND"])
}

@Test("Custom methods are never retried by NetworkRetryPolicy")
func testCustomMethodIsNotRetried() {
    #expect(!NetworkRetryPolicy().shouldRetry(.serverError(.status(503)), method: "PROPFIND"))
}
