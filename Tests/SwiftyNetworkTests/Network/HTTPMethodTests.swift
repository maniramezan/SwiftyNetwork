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
    #expect(HTTPMethod.allCases.count == 7)
}
