import Foundation
import Testing

@testable @_spi(Testing) import SwiftyNetwork

@Suite("authorizationUnavailable classification")
struct AuthorizationUnavailableClassificationTests {
    /// The shape SDKs such as Firebase Auth use: their own error code, the transport error underneath.
    private static func sdkNetworkError(wrapping underlying: any Error) -> NSError {
        NSError(domain: "FIRAuthErrorDomain", code: 17_020, userInfo: [NSUnderlyingErrorKey: underlying])
    }

    @Test("A provider that is offline reads as offline, not as signed out")
    func offlineProviderIsOffline() {
        let error = NetworkError.authorizationUnavailable(underlying: URLError(.notConnectedToInternet))

        #expect(error.classification == .noInternetConnection)
        #expect(error.category == .offline)
        #expect(error.isTransient)
    }

    @Test("A transport failure inside an SDK's own network error is found through NSUnderlyingErrorKey")
    func wrappedTransportFailureIsFound() {
        let error = NetworkError.authorizationUnavailable(
            underlying: Self.sdkNetworkError(wrapping: URLError(.timedOut)))

        #expect(error.category == .timedOut)
        #expect(error.isTransient)
    }

    @Test("An unreachable host behind the provider reads as server unreachable")
    func unreachableHost() {
        let error = NetworkError.authorizationUnavailable(
            underlying: Self.sdkNetworkError(wrapping: URLError(.cannotFindHost)))

        #expect(error.category == .serverUnreachable)
    }

    @Test("A transient NetworkError thrown by the provider keeps its classification")
    func transientNetworkErrorPassesThrough() {
        let error = NetworkError.authorizationUnavailable(underlying: NetworkError.noInternetConnection)

        #expect(error.classification == .noInternetConnection)
    }

    @Test(
        "A provider with no usable session still means sign in again",
        arguments: [
            NSError(domain: "FIRAuthErrorDomain", code: 17_011) as any Error & Sendable,
            URLError(.userAuthenticationRequired),
            NetworkError.unauthorized(HTTPResponse(statusCode: 401)),
            Self.sdkNetworkError(wrapping: URLError(.badServerResponse)),
        ]
    )
    func revokedSessionIsUnauthorized(underlying: any Error & Sendable) {
        let error = NetworkError.authorizationUnavailable(underlying: underlying)

        #expect(error.classification == .authorizationUnavailable)
        #expect(error.category == .unauthorized)
        #expect(!error.isTransient)
    }

    @Test("A cyclic underlying-error chain stops instead of looping")
    func cyclicChainTerminates() {
        let inner = NSMutableDictionary()
        let cyclic = NSError(domain: "Cycle", code: 1, userInfo: inner as? [String: Any])
        inner[NSUnderlyingErrorKey] = cyclic
        let error = NetworkError.authorizationUnavailable(underlying: cyclic)

        #expect(error.classification == .authorizationUnavailable)
    }
}
