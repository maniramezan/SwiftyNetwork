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

@Test("NetworkError covers all cases")
func testAllNetworkErrorCases() {
    let notFound = NetworkError.notFound
    #expect(
        notFound.errorDescription?.contains("404") == true || notFound.errorDescription?.contains("not found") == true)

    let unauthorized = NetworkError.unauthorized
    #expect(
        unauthorized.errorDescription?.contains("401") == true
            || unauthorized.errorDescription?.contains("Unauthorized") == true)

    let forbidden = NetworkError.forbidden
    #expect(
        forbidden.errorDescription?.contains("403") == true || forbidden.errorDescription?.contains("forbidden") == true
    )

    let timeout = NetworkError.timeout
    #expect(timeout.errorDescription?.contains("timed out") == true)

    let noConnection = NetworkError.noInternetConnection
    #expect(
        noConnection.errorDescription?.contains("internet") == true
            || noConnection.errorDescription?.contains("network") == true)

    let invalidResponse = NetworkError.invalidResponse
    #expect(invalidResponse.errorDescription?.contains("response") == true)

    let invalidData = NetworkError.invalidData
    #expect(invalidData.errorDescription?.contains("data") == true)

    let authRefresh = NetworkError.authorizationRefreshFailed
    #expect(
        authRefresh.errorDescription?.contains("authorization") == true
            || authRefresh.errorDescription?.contains("refresh") == true)

    let underlying = NetworkError.underlying(URLError(.badURL))
    #expect(underlying.errorDescription != nil)

    let encoding = NetworkError.encodingFailed(underlying: URLError(.badURL))
    #expect(encoding.errorDescription?.contains("encode") == true)
}

@Test("NetworkError serverErrorData returns nil for non-server errors")
func testServerErrorDataReturnsNilForNonServerErrors() {
    #expect(NetworkError.notFound.serverErrorData == nil)
    #expect(NetworkError.unauthorized.serverErrorData == nil)
    #expect(NetworkError.timeout.serverErrorData == nil)
}
