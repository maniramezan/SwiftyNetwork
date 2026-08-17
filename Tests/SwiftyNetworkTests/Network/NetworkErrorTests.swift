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

@Test("classification maps every NetworkError case to the matching NetworkErrorClassification")
func testClassificationMapsEveryCase() {
    #expect(NetworkError.invalidURL(url: "x").classification == .invalidURL)
    #expect(NetworkError.invalidResponse.classification == .invalidResponse)
    #expect(NetworkError.invalidData.classification == .invalidData)
    #expect(NetworkError.serverError(statusCode: 503, data: nil).classification == .serverError(statusCode: 503))
    #expect(NetworkError.unauthorized.classification == .unauthorized)
    #expect(NetworkError.forbidden.classification == .forbidden)
    #expect(NetworkError.notFound.classification == .notFound)
    #expect(NetworkError.timeout.classification == .timeout)
    #expect(NetworkError.noInternetConnection.classification == .noConnection)
    #expect(NetworkError.decodingFailed(underlying: URLError(.badURL)).classification == .decodingFailed)
    #expect(NetworkError.encodingFailed(underlying: URLError(.badURL)).classification == .encodingFailed)
    #expect(NetworkError.authorizationRefreshFailed.classification == .authorizationRefreshFailed)
    #expect(NetworkError.underlying(URLError(.badURL)).classification == .underlying)
}

@Test("isTransient matches classification.isTransient for every case")
func testIsTransientMatchesClassification() {
    let errors: [NetworkError] = [
        .invalidURL(url: "x"),
        .invalidResponse,
        .invalidData,
        .serverError(statusCode: 500, data: nil),
        .serverError(statusCode: 499, data: nil),
        .unauthorized,
        .forbidden,
        .notFound,
        .timeout,
        .noInternetConnection,
        .decodingFailed(underlying: URLError(.badURL)),
        .encodingFailed(underlying: URLError(.badURL)),
        .authorizationRefreshFailed,
        .underlying(URLError(.badURL)),
    ]
    for error in errors {
        #expect(error.isTransient == error.classification.isTransient)
    }
}

@Test("isTransient is true only for timeouts, missing connectivity, invalid responses, and 5xx errors")
func testIsTransientClassifiesTransientErrors() {
    #expect(NetworkError.timeout.isTransient)
    #expect(NetworkError.noInternetConnection.isTransient)
    #expect(NetworkError.invalidResponse.isTransient)
    #expect(NetworkError.serverError(statusCode: 500, data: nil).isTransient)
    #expect(NetworkError.serverError(statusCode: 503, data: nil).isTransient)

    #expect(!NetworkError.serverError(statusCode: 499, data: nil).isTransient)
    #expect(!NetworkError.unauthorized.isTransient)
    #expect(!NetworkError.forbidden.isTransient)
    #expect(!NetworkError.notFound.isTransient)
    #expect(!NetworkError.invalidURL(url: "x").isTransient)
    #expect(!NetworkError.invalidData.isTransient)
    #expect(!NetworkError.decodingFailed(underlying: URLError(.badURL)).isTransient)
    #expect(!NetworkError.encodingFailed(underlying: URLError(.badURL)).isTransient)
    #expect(!NetworkError.authorizationRefreshFailed.isTransient)
    #expect(!NetworkError.underlying(URLError(.badURL)).isTransient)
}

@Test("mapURLError classifies notConnectedToInternet, timedOut, and other codes")
func testMapURLErrorClassifiesCodes() {
    #expect(NetworkError.mapURLError(URLError(.notConnectedToInternet)).classification == .noConnection)
    #expect(NetworkError.mapURLError(URLError(.timedOut)).classification == .timeout)
    #expect(NetworkError.mapURLError(URLError(.badURL)).classification == .underlying)
}
