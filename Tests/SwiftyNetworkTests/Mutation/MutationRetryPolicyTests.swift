import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("MutationRetryPolicy Tests")
struct MutationRetryPolicyTests {
    @Test("The default policy retries 5 times with the mutation default backoff")
    func defaults() {
        #expect(MutationRetryPolicy.default.maxRetries == 5)
        #expect(MutationRetryPolicy.default.backoff == MutationRetryPolicy.defaultBackoff)
        #expect(MutationRetryPolicy.defaultBackoff.baseDelay == .seconds(1))
        #expect(MutationRetryPolicy.defaultBackoff.maxDelay == .seconds(60))
        #expect(MutationRetryPolicy.defaultBackoff.maxRetryAfter == .seconds(300))
    }

    @Test("Default policy retries timeouts, missing connectivity, invalid responses, 429, and 5xx errors")
    func defaultRetriesTransientErrors() {
        let policy = MutationRetryPolicy.default
        #expect(policy.shouldRetry(NetworkError.timeout(nil)))
        #expect(policy.shouldRetry(NetworkError.noInternetConnection))
        #expect(policy.shouldRetry(NetworkError.invalidResponse))
        #expect(policy.shouldRetry(NetworkError.serverError(.status(500))))
        #expect(policy.shouldRetry(NetworkError.serverError(.status(503))))
        #expect(policy.shouldRetry(NetworkError.tooManyRequests(.status(429, retryAfter: 5))))
    }

    @Test("Default policy does not retry 4xx client errors, encoding failures, or unknown errors")
    func defaultDoesNotRetryNonTransientErrors() {
        let policy = MutationRetryPolicy.default
        #expect(!policy.shouldRetry(NetworkError.unauthorized(.status(401))))
        #expect(!policy.shouldRetry(NetworkError.forbidden(.status(403))))
        #expect(!policy.shouldRetry(NetworkError.notFound(.status(404))))
        #expect(!policy.shouldRetry(NetworkError.clientError(.status(422))))
        #expect(!policy.shouldRetry(NetworkError.invalidURL(url: "bad")))
        #expect(!policy.shouldRetry(URLError(.badURL)))
    }

    @Test("defaultShouldRetry delegates to NetworkError.isTransient, the shared classification source of truth")
    func defaultShouldRetryDelegatesToNetworkErrorIsTransient() {
        let errors: [NetworkError] = [
            .timeout(nil),
            .noInternetConnection,
            .invalidResponse,
            .serverError(.status(500)),
            .clientError(.status(400)),
            .tooManyRequests(.status(429, retryAfter: 5)),
            .unauthorized(.status(401)),
            .forbidden(.status(403)),
            .notFound(.status(404)),
            .invalidURL(url: "bad"),
        ]
        for error in errors {
            #expect(MutationRetryPolicy.defaultShouldRetry(error) == error.isTransient)
        }
    }

    @Test("A custom predicate replaces the default rule")
    func customPredicate() {
        let policy = MutationRetryPolicy(shouldRetry: { _ in true })

        #expect(policy.shouldRetry(NetworkError.clientError(.status(422))))
    }

    @Test("maxRetries is clamped to a non-negative value")
    func negativeMaxRetriesIsClamped() {
        #expect(MutationRetryPolicy(maxRetries: -1).maxRetries == 0)
    }
}
