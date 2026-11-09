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
            .tooManyRequests(.status(429, retryAfter: 5)),
            .tooManyRequests(.status(429)),
            .serverError(.status(500)),
            .serverError(.status(503)),
            .timeout(nil),
            .noInternetConnection,
        ]
        for method in [HTTPMethod.get, .head, .put, .delete] {
            for error in errors {
                #expect(policy.shouldRetry(error, method: method), "\(method) \(error)")
            }
        }
    }

    @Test("shouldRetry matches NetworkError.isTransient for every error except invalidResponse")
    func shouldRetryIsDerivedFromIsTransient() {
        let policy = NetworkRetryPolicy()
        let errors: [NetworkError] = [
            .invalidURL(url: "x"),
            .invalidResponse,
            .invalidData,
            .clientError(.status(499)),
            .serverError(.status(500)),
            .serverError(.status(503)),
            .tooManyRequests(.status(429, retryAfter: 5)),
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
            let expected = error.isTransient && error.classification != .invalidResponse
            #expect(policy.shouldRetry(error, method: .get) == expected, "\(error)")
        }
        #expect(NetworkError.invalidResponse.isTransient)
        #expect(!policy.shouldRetry(.invalidResponse, method: .get))
    }

    @Test("Never retries POST, PATCH or OPTIONS, even on 429")
    func neverRetriesNonIdempotentMethods() {
        let policy = NetworkRetryPolicy()
        for method in [HTTPMethod.post, .patch, .options] {
            #expect(!policy.shouldRetry(.tooManyRequests(.status(429, retryAfter: 1)), method: method))
            #expect(!policy.shouldRetry(.serverError(.status(503)), method: method))
            #expect(!policy.shouldRetry(.timeout(nil), method: method))
            #expect(!policy.shouldRetry(.noInternetConnection, method: method))
        }
    }

    @Test("Does not retry client errors, decoding failures or unclassified errors")
    func doesNotRetryPermanentErrors() {
        let policy = NetworkRetryPolicy()
        let errors: [NetworkError] = [
            .clientError(.status(400)),
            .clientError(.status(499)),
            .unauthorized(.status(401)),
            .forbidden(.status(403)),
            .notFound(.status(404)),
            .invalidResponse,
            .invalidData,
            .invalidURL(url: "x"),
            .decodingFailed(underlying: URLError(.badURL)),
            .encodingFailed(underlying: URLError(.badURL)),
            .authorizationRefreshFailed(underlying: URLError(.userAuthenticationRequired)),
            .underlying(URLError(.cancelled)),
        ]
        for error in errors {
            #expect(!policy.shouldRetry(error, method: .get), "\(error)")
        }
    }

    @Test("Backoff doubles per retry and is capped at maxDelay")
    func backoffDoublesAndCaps() {
        let policy = NetworkRetryPolicy(
            maxRetries: 10, baseDelay: .seconds(1), maxDelay: .seconds(5), jitterRange: 1...1)

        #expect(policy.delay(forRetry: 1) == .seconds(1))
        #expect(policy.delay(forRetry: 2) == .seconds(2))
        #expect(policy.delay(forRetry: 3) == .seconds(4))
        #expect(policy.delay(forRetry: 4) == .seconds(5))
        #expect(policy.delay(forRetry: 10) == .seconds(5))
    }

    @Test("Jitter scales the backoff within the range and never exceeds maxDelay")
    func jitterStaysWithinBounds() {
        let policy = NetworkRetryPolicy(baseDelay: .seconds(4), maxDelay: .seconds(5), jitterRange: 0.5...1.5)

        #expect(policy.delay(forRetry: 1, jitterGenerator: { 0 }) == .seconds(2))
        #expect(policy.delay(forRetry: 1, jitterGenerator: { 1 }) == .seconds(5))
    }

    @Test("Retry-After longer than the backoff sets the delay")
    func retryAfterOverridesBackoff() {
        let policy = NetworkRetryPolicy(
            baseDelay: .seconds(0.5), maxDelay: .seconds(8), jitterRange: 1...1, maxRetryAfter: .seconds(30))
        let error = NetworkError.tooManyRequests(.status(429, retryAfter: 5))

        #expect(policy.delay(forRetry: 1, after: error) == .seconds(5))
    }

    @Test("A huge Retry-After is clamped to maxRetryAfter")
    func hugeRetryAfterIsClamped() {
        let policy = NetworkRetryPolicy(
            baseDelay: .seconds(0.5), maxDelay: .seconds(8), jitterRange: 1...1, maxRetryAfter: .seconds(30))
        let error = NetworkError.tooManyRequests(.status(429, retryAfter: 86_400))

        #expect(policy.delay(forRetry: 1, after: error) == .seconds(30))
    }

    @Test("A Retry-After shorter than the backoff never shortens it")
    func shortRetryAfterKeepsBackoff() {
        let policy = NetworkRetryPolicy(baseDelay: .seconds(4), maxDelay: .seconds(8), jitterRange: 1...1)
        let error = NetworkError.tooManyRequests(.status(429, retryAfter: 1))

        #expect(policy.delay(forRetry: 1, after: error) == .seconds(4))
    }

    @Test("Initializer clamps negative values and keeps maxDelay at or above baseDelay")
    func initializerClampsValues() {
        let policy = NetworkRetryPolicy(
            maxRetries: -1, baseDelay: .seconds(-2), maxDelay: .seconds(-3), maxRetryAfter: .seconds(-4))

        #expect(policy.maxRetries == 0)
        #expect(policy.baseDelay == .seconds(0))
        #expect(policy.maxDelay == .seconds(0))
        #expect(policy.maxRetryAfter == .zero)
        #expect(NetworkRetryPolicy(baseDelay: .seconds(10), maxDelay: .seconds(2)).maxDelay == .seconds(10))
    }

    @Test("The retry policy is off by default")
    func offByDefault() {
        #expect(NetworkClientConfiguration().retryPolicy == nil)
    }
}
