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
            (.tooManyRequests(response(429)), .rejected),
            (.clientError(response(422)), .rejected),
            (.serverError(response(500)), .serverError),
            (.unexpectedStatus(response(302)), .other),
            (.invalidURL(url: "x"), .other),
            (.invalidResponse, .other),
            (.decodingFailed(underlying: Boom()), .other),
            (.encodingFailed(underlying: Boom()), .other),
            (.underlying(Boom()), .other),
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
