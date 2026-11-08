import Foundation
import Testing

@testable import SwiftyNetwork

@Test("NetworkError provides descriptions and server data")
func testNetworkErrorDescriptionsAndData() {
    let serverData = Data("err".utf8)
    let serverError = NetworkError.serverError(statusCode: 500, data: serverData)
    #expect(serverError.responseBody == serverData)
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

    let unauthorized = NetworkError.unauthorized()
    #expect(
        unauthorized.errorDescription?.contains("401") == true
            || unauthorized.errorDescription?.contains("Unauthorized") == true)

    let forbidden = NetworkError.forbidden()
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

@Test("NetworkError responseBody returns nil for non-server errors")
func testServerErrorDataReturnsNilForNonServerErrors() {
    #expect(NetworkError.notFound.responseBody == nil)
    #expect(NetworkError.unauthorized().responseBody == nil)
    #expect(NetworkError.timeout.responseBody == nil)
}

@Test("classification maps every NetworkError case to the matching NetworkErrorClassification")
func testClassificationMapsEveryCase() {
    #expect(NetworkError.invalidURL(url: "x").classification == .invalidURL)
    #expect(NetworkError.invalidResponse.classification == .invalidResponse)
    #expect(NetworkError.invalidData.classification == .invalidData)
    #expect(NetworkError.serverError(statusCode: 503, data: nil).classification == .serverError(statusCode: 503))
    #expect(NetworkError.tooManyRequests(retryAfter: 5, data: Data()).classification == .tooManyRequests)
    #expect(NetworkError.unauthorized().classification == .unauthorized)
    #expect(NetworkError.forbidden().classification == .forbidden)
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
        .tooManyRequests(retryAfter: nil, data: Data()),
        .unauthorized(),
        .forbidden(),
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

@Test("isTransient is true only for timeouts, missing connectivity, invalid responses, 429, and 5xx errors")
func testIsTransientClassifiesTransientErrors() {
    #expect(NetworkError.timeout.isTransient)
    #expect(NetworkError.noInternetConnection.isTransient)
    #expect(NetworkError.invalidResponse.isTransient)
    #expect(NetworkError.serverError(statusCode: 500, data: nil).isTransient)
    #expect(NetworkError.serverError(statusCode: 503, data: nil).isTransient)
    #expect(NetworkError.tooManyRequests(retryAfter: 5, data: Data()).isTransient)
    #expect(NetworkError.tooManyRequests(retryAfter: nil, data: Data()).isTransient)

    #expect(!NetworkError.serverError(statusCode: 499, data: nil).isTransient)
    #expect(!NetworkError.unauthorized().isTransient)
    #expect(!NetworkError.forbidden().isTransient)
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

@Test("Underlying URL errors keep their localized description")
func testUnderlyingErrorKeepsLocalizedDescription() {
    let urlError = URLError(.cannotFindHost)
    let error = NetworkError.mapURLError(urlError)

    // Reading through `any Error` must preserve the original localized message.
    #expect(error.errorDescription?.contains(urlError.localizedDescription) == true)
    if case .underlying(let underlying) = error {
        #expect(underlying.localizedDescription == urlError.localizedDescription)
    } else {
        Issue.record("Expected .underlying, got \(error)")
    }
}

@Test("mapURLError treats connectivity-loss codes as no connection")
func testMapURLErrorTreatsConnectivityLossAsNoConnection() {
    let codes: [URLError.Code] = [.networkConnectionLost, .dataNotAllowed, .internationalRoamingOff]
    for code in codes {
        let mapped = NetworkError.mapURLError(URLError(code))
        #expect(mapped.classification == .noConnection)
        #expect(mapped.isTransient)
    }
}

@Test("mapURLError preserves the original URLError for unmapped codes")
func testMapURLErrorPreservesUnderlyingURLError() throws {
    guard case .underlying(let underlying) = NetworkError.mapURLError(URLError(.cannotFindHost)) else {
        Issue.record("Expected .underlying")
        return
    }
    let urlError = try #require(underlying as? URLError)
    #expect(urlError.code == .cannotFindHost)
}

@Test("tooManyRequests exposes retryAfter and its response body, and describes itself")
func testTooManyRequestsAccessors() {
    let body = Data(#"{"code":"throttled"}"#.utf8)
    let error = NetworkError.tooManyRequests(retryAfter: 5, data: body)

    #expect(error.retryAfter == 5)
    #expect(error.responseBody == body)
    #expect(error.errorDescription?.contains("Too many requests") == true)
    #expect(NetworkError.tooManyRequests(retryAfter: nil, data: Data()).retryAfter == nil)
    #expect(NetworkError.serverError(statusCode: 503, data: nil).retryAfter == nil)
    #expect(NetworkError.timeout.retryAfter == nil)
}

@Test("serverError exposes retryAfter, its response body, and its response")
func testServerErrorRetryAfterAccessors() {
    let body = Data("maintenance".utf8)
    let response = HTTPErrorResponse(statusCode: 503, headers: ["Retry-After": "30"], body: body)
    let error = NetworkError.serverError(statusCode: 503, data: body, retryAfter: 30, response: response)

    #expect(error.retryAfter == 30)
    #expect(error.responseBody == body)
    #expect(error.response == response)
    #expect(error.classification == .serverError(statusCode: 503))
}
