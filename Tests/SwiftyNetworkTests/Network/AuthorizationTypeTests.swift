import Foundation
import Testing

@testable import SwiftyNetwork

@Test("AuthorizationType applies expected headers")
func testAuthorizationTypeAppliesHeaders() {
    var request = URLRequest(url: URL(string: "https://api.test.com")!)

    AuthorizationType.basic(token: "basic").apply(to: &request)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic basic")

    AuthorizationType.bearer(token: "bearer").apply(to: &request)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer bearer")

    AuthorizationType.apiKey(key: "key", header: "X-API").apply(to: &request)
    #expect(request.value(forHTTPHeaderField: "X-API") == "key")

    AuthorizationType.custom(header: "X-Custom", value: "value").apply(to: &request)
    #expect(request.value(forHTTPHeaderField: "X-Custom") == "value")
}
