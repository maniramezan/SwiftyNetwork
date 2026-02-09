import Testing

@testable import SwiftyNetwork

@Test("HTTPMethod raw values")
func testHTTPMethodRawValues() {
    #expect(HTTPMethod.get.rawValue == "GET")
    #expect(HTTPMethod.post.rawValue == "POST")
    #expect(HTTPMethod.put.rawValue == "PUT")
    #expect(HTTPMethod.delete.rawValue == "DELETE")
    #expect(HTTPMethod.patch.rawValue == "PATCH")
    #expect(HTTPMethod.allCases.count == 5)
}
