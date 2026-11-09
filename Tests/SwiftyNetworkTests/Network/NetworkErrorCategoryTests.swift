import Foundation
import SwiftyNetworkTesting
import Testing

@testable import SwiftyNetwork

@Suite("NetworkError category")
struct NetworkErrorCategoryTests {
    private struct Boom: Error {}

    private static func response(_ code: Int) -> HTTPResponse { HTTPResponse(statusCode: code) }

    @Test(
        "Every error maps to one category",
        arguments: [
            (NetworkError.noInternetConnection, NetworkErrorCategory.offline),
            (.timeout(nil), .timedOut),
            (.timeout(response(408)), .timedOut),
            (.unauthorized(response(401)), .unauthorized),
            (.authorizationUnavailable(underlying: Boom()), .unauthorized),
            (.authorizationRefreshFailed(underlying: Boom()), .unauthorized),
            (.forbidden(response(403)), .rejected),
            (.notFound(response(404)), .rejected),
            (.tooManyRequests(response(429)), .rateLimited),
            (.clientError(response(422)), .rejected),
            (.serverError(response(500)), .serverError),
            (.unexpectedStatus(response(302)), .other),
            (.invalidURL(url: "x"), .other),
            (.invalidResponse, .other),
            (.decodingFailed(underlying: Boom()), .other),
            (.encodingFailed(underlying: Boom()), .other),
            (.underlying(Boom()), .other),
            (.underlying(URLError(.serverCertificateUntrusted)), .insecureConnection),
            (.underlying(URLError(.secureConnectionFailed)), .insecureConnection),
            (.underlying(URLError(.cancelled)), .insecureConnection),
            (.underlying(URLError(.badServerResponse)), .other),
        ]
    )
    func category(error: NetworkError, expected: NetworkErrorCategory) {
        #expect(error.category == expected)
        #expect(error.classification.category == expected)
    }

    @Test("MutationFailureReason keeps its cancellation category")
    func mutationCategoryUnchanged() {
        #expect(MutationFailureReason(NetworkError.underlying(CancellationError())).category == .cancelled)
        #expect(MutationFailureReason(NetworkError.noInternetConnection).category == .offline)
    }

    @Test("MutationFailureReason has the rate-limited and insecure-connection categories")
    func mutationNewCategories() {
        let rateLimited = MutationFailureReason(NetworkError.tooManyRequests(Self.response(429)))
        let insecure = MutationFailureReason(NetworkError.underlying(URLError(.serverCertificateUntrusted)))
        #expect(rateLimited.category == .rateLimited)
        #expect(rateLimited.isTransient)
        #expect(insecure.category == .insecureConnection)
        #expect(!insecure.isTransient)
    }

    @Test("mapTransportError maps URLErrors like the client and passes NetworkError through")
    func mapTransportError() {
        let offline = NetworkError.mapTransportError(URLError(.networkConnectionLost)) as? NetworkError
        let timedOut = NetworkError.mapTransportError(URLError(.timedOut)) as? NetworkError
        let other = NetworkError.mapTransportError(Boom()) as? NetworkError
        let passedThrough = NetworkError.mapTransportError(NetworkError.notFound(Self.response(404))) as? NetworkError
        #expect(offline?.classification == .noInternetConnection)
        #expect(timedOut?.classification == .timeout)
        #expect(other?.classification == .underlying)
        #expect(passedThrough?.statusCode == 404)
        #expect(NetworkError.mapTransportError(CancellationError()) is CancellationError)
    }

    @Test("mapTransportError turns URLError.cancelled into CancellationError when the task is cancelled")
    func mapTransportErrorCancelled() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return NetworkError.mapTransportError(URLError(.cancelled))
        }
        #expect(await task.value is CancellationError)
    }
}

@Suite("AuthorizationProvider helpers")
struct AuthorizationProviderHelperTests {
    @Test("isCurrentAuthorization compares against the provider's current authorization")
    func isCurrent() async {
        let provider = TestAuthorizationProvider(current: .bearer(token: "b"), refreshResult: true)
        #expect(await provider.isCurrentAuthorization(.bearer(token: "b")))
        #expect(await !provider.isCurrentAuthorization(.bearer(token: "a")))
    }

    @Test("isCurrentAuthorization is true when the provider has no authorization")
    func isCurrentWhenUnavailable() async {
        struct Throwing: AuthorizationProvider {
            struct SignedOut: Error {}
            func currentAuthorization() async throws -> AuthorizationType { throw SignedOut() }
            func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {}
        }
        #expect(await Throwing().isCurrentAuthorization(.bearer(token: "a")))
    }

    @Test("TestAuthorizationProvider outcomes can change after creation")
    func settableOutcomes() async throws {
        let provider = TestAuthorizationProvider(current: .bearer(token: "a"), refreshResult: false)
        await #expect(throws: TestAuthorizationProvider.RefreshFailed.self) {
            try await provider.refreshAuthorization(rejecting: .bearer(token: "a"))
        }

        await provider.setRefreshResult(true)
        await provider.setRefreshedAuthorization(.bearer(token: "b"))
        try await provider.refreshAuthorization(rejecting: .bearer(token: "a"))
        #expect(await provider.currentAuthorization() == .bearer(token: "b"))
        #expect(await provider.refreshCallCount == 2)

        await provider.setCurrentAuthorization(.bearer(token: "c"))
        #expect(await provider.currentAuthorization() == .bearer(token: "c"))
    }
}
