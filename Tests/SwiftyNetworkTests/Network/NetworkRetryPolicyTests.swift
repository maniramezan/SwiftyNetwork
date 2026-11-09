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

    @Test("shouldRetry matches NetworkError.isTransient for every error")
    func shouldRetryIsDerivedFromIsTransient() {
        let policy = NetworkRetryPolicy()
        let errors: [NetworkError] = [
            .invalidURL(url: "x"),
            .invalidResponse,
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
            #expect(policy.shouldRetry(error, method: .get) == error.isTransient, "\(error)")
        }
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

    @Test("The default policy retries twice with the network default backoff")
    func defaults() {
        #expect(NetworkRetryPolicy.default.maxRetries == 2)
        #expect(NetworkRetryPolicy.default.backoff == NetworkRetryPolicy.defaultBackoff)
        #expect(NetworkRetryPolicy.defaultBackoff.baseDelay == .milliseconds(500))
        #expect(NetworkRetryPolicy.defaultBackoff.maxDelay == .seconds(8))
        #expect(NetworkRetryPolicy.defaultBackoff.maxRetryAfter == .seconds(30))
    }

    @Test("maxRetries is clamped to a non-negative value")
    func negativeMaxRetriesIsClamped() {
        #expect(NetworkRetryPolicy(maxRetries: -1).maxRetries == 0)
    }

    @Test("The retry policy is off by default")
    func offByDefault() {
        #expect(NetworkClientConfiguration().retryPolicy == nil)
    }
}
