import Foundation
import Testing

@testable import SwiftyNetwork

@Test("NetworkError provides descriptions and server data")
func testNetworkErrorDescriptionsAndData() {
    let serverData = Data("err".utf8)
    let serverError = NetworkError.serverError(statusCode: 500, data: serverData)
    #expect(serverError.serverErrorData == serverData)
    #expect(serverError.errorDescription?.contains("500") == true)

    let invalidURL = NetworkError.invalidURL(url: "nope")
    #expect(invalidURL.errorDescription?.contains("Invalid URL") == true)

    let decoding = NetworkError.decodingFailed(underlying: URLError(.cannotDecodeContentData))
    #expect(decoding.errorDescription?.contains("Failed to decode response") == true)
}
