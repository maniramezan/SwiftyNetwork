import Foundation
import Testing

@testable import SwiftyNetwork

@Test("AuthorizationType applies expected headers")
func testAuthorizationTypeAppliesHeaders() {
    var request = URLRequest(url: URL(string: "https://api.test.com")!)

    AuthorizationType.basicEncoded(credential: "basic").apply(to: &request)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic basic")

    AuthorizationType.basic(username: "user", password: "pass").apply(to: &request)
    let expected = Data("user:pass".utf8).base64EncodedString()
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Basic \(expected)")

    AuthorizationType.bearer(token: "bearer").apply(to: &request)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer bearer")

    AuthorizationType.apiKey(key: "key", header: "X-API").apply(to: &request)
    #expect(request.value(forHTTPHeaderField: "X-API") == "key")

    AuthorizationType.custom(header: "X-Custom", value: "value").apply(to: &request)
    #expect(request.value(forHTTPHeaderField: "X-Custom") == "value")
}
