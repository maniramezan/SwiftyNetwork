import Foundation
import Testing

@testable import SwiftyNetwork

@Test("NetworkError provides descriptions and server data")
func testNetworkErrorDescriptionsAndData() {
    let serverData = Data("err".utf8)
    let serverError = NetworkError.serverError(.status(500, body: serverData))
    #expect(serverError.response?.body == serverData)
    #expect(serverError.errorDescription?.contains("500") == true)

    let invalidURL = NetworkError.invalidURL(url: "nope")
    #expect(invalidURL.errorDescription?.contains("Invalid URL") == true)

    let decoding = NetworkError.decodingFailed(underlying: URLError(.cannotDecodeContentData))
    #expect(decoding.errorDescription?.contains("Failed to decode response") == true)
}

@Test("NetworkError covers all cases")
func testAllNetworkErrorCases() {
    let notFound = NetworkError.notFound(.status(404))
    #expect(
        notFound.errorDescription?.contains("404") == true || notFound.errorDescription?.contains("not found") == true)

    let unauthorized = NetworkError.unauthorized(.status(401))
    #expect(
        unauthorized.errorDescription?.contains("401") == true
            || unauthorized.errorDescription?.contains("Unauthorized") == true)

    let forbidden = NetworkError.forbidden(.status(403))
    #expect(
        forbidden.errorDescription?.contains("403") == true || forbidden.errorDescription?.contains("forbidden") == true
    )

    let timeout = NetworkError.timeout(nil)
    #expect(timeout.errorDescription?.contains("timed out") == true)

    let noConnection = NetworkError.noInternetConnection
    #expect(
        noConnection.errorDescription?.contains("internet") == true
            || noConnection.errorDescription?.contains("network") == true)

    let invalidResponse = NetworkError.invalidResponse
    #expect(invalidResponse.errorDescription?.contains("response") == true)

    let authRefresh = NetworkError.authorizationRefreshFailed(underlying: URLError(.userAuthenticationRequired))
    #expect(
        authRefresh.errorDescription?.contains("authorization") == true
            || authRefresh.errorDescription?.contains("refresh") == true)

    let underlying = NetworkError.underlying(URLError(.badURL))
    #expect(underlying.errorDescription != nil)

    let encoding = NetworkError.encodingFailed(underlying: URLError(.badURL))
    #expect(encoding.errorDescription?.contains("encode") == true)
}

@Test("statusCode reads the HTTP status and is nil for non-HTTP errors")
func testStatusCodeAccessor() {
    #expect(NetworkError.notFound(.status(404)).statusCode == 404)
    #expect(NetworkError.clientError(.status(422)).statusCode == 422)
    #expect(NetworkError.timeout(.status(408)).statusCode == 408)
    #expect(NetworkError.timeout(nil).statusCode == nil)
    #expect(NetworkError.noInternetConnection.statusCode == nil)
}

@Test("Each 4xx and 5xx status maps to its own NetworkError case")
func testStatusMapping() {
    let cases: [(Int, NetworkErrorClassification)] = [
        (400, .clientError(statusCode: 400)),
        (401, .unauthorized),
        (403, .forbidden),
        (404, .notFound),
        (408, .timeout),
        (409, .clientError(statusCode: 409)),
        (422, .clientError(statusCode: 422)),
        (429, .tooManyRequests),
        (499, .clientError(statusCode: 499)),
        (500, .serverError(statusCode: 500)),
        (503, .serverError(statusCode: 503)),
        (599, .serverError(statusCode: 599)),
        (304, .unexpectedStatus(statusCode: 304)),
        (600, .unexpectedStatus(statusCode: 600)),
    ]
    for (status, expected) in cases {
        let error = HTTPStatusValidator.error(for: .status(status))
        #expect(error.classification == expected, "status \(status)")
        #expect(error.response?.statusCode == status)
    }
}

@Test("classification maps every NetworkError case to the matching NetworkErrorClassification")
func testClassificationMapsEveryCase() {
    #expect(NetworkError.invalidURL(url: "x").classification == .invalidURL)
    #expect(NetworkError.invalidResponse.classification == .invalidResponse)
    #expect(NetworkError.clientError(.status(422)).classification == .clientError(statusCode: 422))
    #expect(NetworkError.serverError(.status(503)).classification == .serverError(statusCode: 503))
    #expect(NetworkError.unexpectedStatus(.status(304)).classification == .unexpectedStatus(statusCode: 304))
    #expect(NetworkError.tooManyRequests(.status(429, retryAfter: 5)).classification == .tooManyRequests)
    #expect(NetworkError.unauthorized(.status(401)).classification == .unauthorized)
    #expect(NetworkError.forbidden(.status(403)).classification == .forbidden)
    #expect(NetworkError.notFound(.status(404)).classification == .notFound)
    #expect(NetworkError.timeout(nil).classification == .timeout)
    #expect(NetworkError.noInternetConnection.classification == .noConnection)
    #expect(NetworkError.decodingFailed(underlying: URLError(.badURL)).classification == .decodingFailed)
    #expect(NetworkError.encodingFailed(underlying: URLError(.badURL)).classification == .encodingFailed)
    #expect(
        NetworkError.authorizationRefreshFailed(underlying: URLError(.userAuthenticationRequired)).classification
            == .authorizationRefreshFailed)
    #expect(NetworkError.underlying(URLError(.badURL)).classification == .underlying)
}

@Test("isTransient matches classification.isTransient for every case")
func testIsTransientMatchesClassification() {
    let errors: [NetworkError] = [
        .invalidURL(url: "x"),
        .invalidResponse,
        .serverError(.status(500)),
        .clientError(.status(499)),
        .unexpectedStatus(.status(304)),
        .tooManyRequests(.status(429)),
        .unauthorized(.status(401)),
        .forbidden(.status(403)),
        .notFound(.status(404)),
        .timeout(nil),
        .noInternetConnection,
        .decodingFailed(underlying: URLError(.badURL)),
        .encodingFailed(underlying: URLError(.badURL)),
        .authorizationRefreshFailed(underlying: URLError(.userAuthenticationRequired)),
        .underlying(URLError(.badURL)),
    ]
    for error in errors {
        #expect(error.isTransient == error.classification.isTransient)
    }
}

@Test("isTransient is true only for timeouts, missing connectivity, 429, and 5xx errors")
func testIsTransientClassifiesTransientErrors() {
    #expect(NetworkError.timeout(nil).isTransient)
    #expect(NetworkError.noInternetConnection.isTransient)
    #expect(NetworkError.serverError(.status(500)).isTransient)
    #expect(NetworkError.serverError(.status(503)).isTransient)
    #expect(NetworkError.tooManyRequests(.status(429, retryAfter: 5)).isTransient)
    #expect(NetworkError.tooManyRequests(.status(429)).isTransient)

    #expect(!NetworkError.clientError(.status(499)).isTransient)
    #expect(!NetworkError.unexpectedStatus(.status(304)).isTransient)
    #expect(!NetworkError.unauthorized(.status(401)).isTransient)
    #expect(!NetworkError.forbidden(.status(403)).isTransient)
    #expect(!NetworkError.notFound(.status(404)).isTransient)
    #expect(!NetworkError.invalidURL(url: "x").isTransient)
    #expect(!NetworkError.invalidResponse.isTransient)
    #expect(!NetworkError.decodingFailed(underlying: URLError(.badURL)).isTransient)
    #expect(!NetworkError.encodingFailed(underlying: URLError(.badURL)).isTransient)
    #expect(!NetworkError.authorizationRefreshFailed(underlying: URLError(.userAuthenticationRequired)).isTransient)
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

@Test("transportError turns a cancelled URLError into CancellationError only when the task is cancelled")
func testTransportErrorTranslatesTaskCancellation() async {
    let notCancelled = NetworkError.transportError(URLError(.cancelled))
    guard case .underlying(let underlying) = notCancelled as? NetworkError else {
        Issue.record("Expected .underlying for a cancelled URLError outside task cancellation, got \(notCancelled)")
        return
    }
    #expect((underlying as? URLError)?.code == .cancelled)

    let cancelled = await Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return NetworkError.transportError(URLError(.cancelled))
    }.value
    #expect(cancelled is CancellationError)
}

@Test("transportError passes CancellationError through and maps other errors")
func testTransportErrorMapsOtherErrors() {
    #expect(NetworkError.transportError(CancellationError()) is CancellationError)
    #expect((NetworkError.transportError(URLError(.timedOut)) as? NetworkError)?.classification == .timeout)

    struct Unrelated: Error {}
    #expect((NetworkError.transportError(Unrelated()) as? NetworkError)?.classification == .underlying)
}

@Test("tooManyRequests exposes retryAfter and its response body, and describes itself")
func testTooManyRequestsAccessors() {
    let body = Data(#"{"code":"throttled"}"#.utf8)
    let error = NetworkError.tooManyRequests(.status(429, retryAfter: 5, body: body))

    #expect(error.retryAfter == .seconds(5))
    #expect(error.response?.body == body)
    #expect(error.errorDescription?.contains("Too many requests") == true)
    #expect(NetworkError.tooManyRequests(.status(429)).retryAfter == nil)
    #expect(NetworkError.serverError(.status(503)).retryAfter == nil)
    #expect(NetworkError.timeout(nil).retryAfter == nil)
}

@Test("serverError exposes retryAfter, its response body, and its response")
func testServerErrorRetryAfterAccessors() {
    let body = Data("maintenance".utf8)
    let response = HTTPErrorResponse(statusCode: 503, headers: ["Retry-After": "30"], body: body)
    let error = NetworkError.serverError(response)

    #expect(error.retryAfter == .seconds(30))
    #expect(error.response?.body == body)
    #expect(error.response == response)
    #expect(error.classification == .serverError(statusCode: 503))
}
