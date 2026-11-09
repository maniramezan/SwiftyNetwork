import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("MutationFailureReason Tests")
struct MutationFailureReasonTests {
    @Test(
        "Each error maps to the category a UI must handle",
        arguments: [
            (NetworkError.noInternetConnection, MutationFailureReason.Category.offline),
            (.timeout(nil), .timedOut),
            (.timeout(.status(408)), .timedOut),
            (.unauthorized(.status(401)), .unauthorized),
            (.authorizationRefreshFailed(underlying: URLError(.userAuthenticationRequired)), .unauthorized),
            (.authorizationUnavailable(underlying: URLError(.userAuthenticationRequired)), .unauthorized),
            (.forbidden(.status(403)), .rejected),
            (.notFound(.status(404)), .rejected),
            (.clientError(.status(400)), .rejected),
            (.clientError(.status(409)), .rejected),
            (.clientError(.status(422)), .rejected),
            (.tooManyRequests(.status(429)), .rateLimited),
            (.serverError(.status(500)), .serverError),
            (.serverError(.status(503)), .serverError),
            (.unexpectedStatus(.status(304)), .other),
            (.invalidURL(url: "x"), .other),
            (.invalidResponse, .other),
            (.decodingFailed(underlying: URLError(.cannotDecodeContentData)), .other),
            (.underlying(URLError(.badURL)), .other),
            (.underlying(CancellationError()), .cancelled),
        ]
    )
    func categoryForNetworkError(error: NetworkError, expected: MutationFailureReason.Category) {
        let reason = MutationFailureReason(error)

        #expect(reason.category == expected)
        #expect(reason.classification == error.classification)
        #expect(reason.response == error.response)
        #expect(reason.isTransient == error.isTransient)
        #expect(reason.isCancellation == (expected == .cancelled))
    }

    @Test("A 4xx rejection keeps the response so the app can read the API error")
    func rejectionKeepsResponse() throws {
        let body = Data(#"{"code":"title_too_long"}"#.utf8)
        let reason = MutationFailureReason(NetworkError.clientError(.status(422, body: body)))

        #expect(reason.category == .rejected)
        #expect(reason.statusCode == 422)
        #expect(reason.response?.body == body)
        #expect(!reason.isTransient)
    }

    @Test("Offline has no response and is transient, unlike a 4xx rejection")
    func offlineDiffersFromRejection() {
        let offline = MutationFailureReason(NetworkError.noInternetConnection)
        let rejected = MutationFailureReason(NetworkError.clientError(.status(400)))

        #expect(offline.category == .offline)
        #expect(offline.statusCode == nil)
        #expect(offline.isTransient)
        #expect(offline != rejected)
    }

    @Test("Errors outside NetworkError are cancelled or other, with no classification")
    func foreignErrors() {
        let cancelled = MutationFailureReason(CancellationError())
        let foreign = MutationFailureReason(URLError(.badURL))

        #expect(cancelled.category == .cancelled)
        #expect(cancelled.isCancellation)
        #expect(foreign.category == .other)
        #expect(foreign.classification == nil)
        #expect(!foreign.isTransient)
    }
}
