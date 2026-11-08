import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("NetworkRetryPolicy Tests")
struct NetworkRetryPolicyTests {
    @Test("Only GET, HEAD, PUT and DELETE are retryable methods")
    func retryableMethods() {
        #expect(NetworkRetryPolicy.retryableMethods == [.get, .head, .put, .delete])
    }

    @Test("Retries 429, 5xx, timeouts and lost connectivity on idempotent methods")
    func retriesTransientErrorsOnIdempotentMethods() {
        let policy = NetworkRetryPolicy()
        let errors: [NetworkError] = [
            .tooManyRequests(retryAfter: 5, data: nil),
            .tooManyRequests(retryAfter: nil, data: nil),
            .serverError(statusCode: 500, data: nil),
            .serverError(statusCode: 503, data: nil),
            .timeout,
            .noInternetConnection,
        ]
        for method in [HTTPMethod.get, .head, .put, .delete] {
            for error in errors {
                #expect(policy.shouldRetry(error, method: method), "\(method) \(error)")
            }
        }
    }

    @Test("Never retries POST, PATCH or OPTIONS, even on 429")
    func neverRetriesNonIdempotentMethods() {
        let policy = NetworkRetryPolicy()
        for method in [HTTPMethod.post, .patch, .options] {
            #expect(!policy.shouldRetry(.tooManyRequests(retryAfter: 1, data: nil), method: method))
            #expect(!policy.shouldRetry(.serverError(statusCode: 503, data: nil), method: method))
            #expect(!policy.shouldRetry(.timeout, method: method))
            #expect(!policy.shouldRetry(.noInternetConnection, method: method))
        }
    }

    @Test("Does not retry client errors, decoding failures or unclassified errors")
    func doesNotRetryPermanentErrors() {
        let policy = NetworkRetryPolicy()
        let errors: [NetworkError] = [
            .serverError(statusCode: 400, data: nil),
            .serverError(statusCode: 499, data: nil),
            .unauthorized(),
            .forbidden(),
            .notFound,
            .invalidResponse,
            .invalidData,
            .invalidURL(url: "x"),
            .decodingFailed(underlying: URLError(.badURL)),
            .encodingFailed(underlying: URLError(.badURL)),
            .authorizationRefreshFailed,
            .underlying(URLError(.cancelled)),
        ]
        for error in errors {
            #expect(!policy.shouldRetry(error, method: .get), "\(error)")
        }
    }

    @Test("Backoff doubles per retry and is capped at maxDelay")
    func backoffDoublesAndCaps() {
        let policy = NetworkRetryPolicy(maxRetries: 10, baseDelay: 1, maxDelay: 5, jitterRange: 1...1)

        #expect(policy.delay(forRetry: 1) == 1)
        #expect(policy.delay(forRetry: 2) == 2)
        #expect(policy.delay(forRetry: 3) == 4)
        #expect(policy.delay(forRetry: 4) == 5)
        #expect(policy.delay(forRetry: 10) == 5)
    }

    @Test("Jitter scales the backoff within the range and never exceeds maxDelay")
    func jitterStaysWithinBounds() {
        let policy = NetworkRetryPolicy(baseDelay: 4, maxDelay: 5, jitterRange: 0.5...1.5)

        #expect(policy.delay(forRetry: 1, jitterGenerator: { 0 }) == 2)
        #expect(policy.delay(forRetry: 1, jitterGenerator: { 1 }) == 5)
    }

    @Test("Retry-After longer than the backoff sets the delay")
    func retryAfterOverridesBackoff() {
        let policy = NetworkRetryPolicy(baseDelay: 0.5, maxDelay: 8, jitterRange: 1...1, maxRetryAfter: 30)
        let error = NetworkError.tooManyRequests(retryAfter: 5, data: nil)

        #expect(policy.delay(forRetry: 1, after: error) == 5)
    }

    @Test("A huge Retry-After is clamped to maxRetryAfter")
    func hugeRetryAfterIsClamped() {
        let policy = NetworkRetryPolicy(baseDelay: 0.5, maxDelay: 8, jitterRange: 1...1, maxRetryAfter: 30)
        let error = NetworkError.tooManyRequests(retryAfter: 86_400, data: nil)

        #expect(policy.delay(forRetry: 1, after: error) == 30)
    }

    @Test("A Retry-After shorter than the backoff never shortens it")
    func shortRetryAfterKeepsBackoff() {
        let policy = NetworkRetryPolicy(baseDelay: 4, maxDelay: 8, jitterRange: 1...1)
        let error = NetworkError.tooManyRequests(retryAfter: 1, data: nil)

        #expect(policy.delay(forRetry: 1, after: error) == 4)
    }

    @Test("Initializer clamps negative values and keeps maxDelay at or above baseDelay")
    func initializerClampsValues() {
        let policy = NetworkRetryPolicy(maxRetries: -1, baseDelay: -2, maxDelay: -3, maxRetryAfter: -4)

        #expect(policy.maxRetries == 0)
        #expect(policy.baseDelay == 0)
        #expect(policy.maxDelay == 0)
        #expect(policy.maxRetryAfter == 0)
        #expect(NetworkRetryPolicy(baseDelay: 10, maxDelay: 2).maxDelay == 10)
    }

    @Test("The retry policy is off by default")
    func offByDefault() {
        #expect(NetworkClientConfiguration().retryPolicy == nil)
    }
}
