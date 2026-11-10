import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("NetworkRetryPolicy Tests")
struct NetworkRetryPolicyTests {
    @Test("GET, HEAD, PUT, DELETE and OPTIONS are idempotent by default")
    func defaultIdempotency() {
        for method in [HTTPMethod.get, .head, .put, .delete, .options] {
            #expect(method.isIdempotent)
        }
        for method in [HTTPMethod.post, .patch] {
            #expect(!method.isIdempotent)
        }
    }

    @Test("Retries 429, 5xx, timeouts, lost connectivity and unreachable hosts on idempotent methods")
    func retriesTransientErrorsOnIdempotentMethods() {
        let policy = NetworkRetryPolicy()
        let errors: [NetworkError] = [
            .tooManyRequests(.status(429, retryAfter: 5)),
            .tooManyRequests(.status(429)),
            .serverError(.status(500)),
            .serverError(.status(503)),
            .timeout(nil),
            .noInternetConnection,
            .serverUnreachable(URLError(.cannotFindHost)),
        ]
        for method in [HTTPMethod.get, .head, .put, .delete, .options] {
            for error in errors {
                #expect(policy.shouldRetry(error, isIdempotent: method.isIdempotent), "\(method) \(error)")
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
            .serverUnreachable(URLError(.cannotConnectToHost)),
            .decodingFailed(underlying: URLError(.badURL)),
            .encodingFailed(underlying: URLError(.badURL)),
            .authorizationRefreshFailed(underlying: URLError(.userAuthenticationRequired)),
            .underlying(URLError(.badURL)),
        ]
        for error in errors {
            #expect(policy.shouldRetry(error, isIdempotent: true) == error.isTransient, "\(error)")
        }
    }

    @Test("Never retries a non-idempotent request, even on transient failures")
    func neverRetriesNonIdempotentRequests() {
        let policy = NetworkRetryPolicy()
        for error in [
            NetworkError.tooManyRequests(.status(429, retryAfter: 1)),
            .serverError(.status(503)),
            .timeout(nil),
            .noInternetConnection,
        ] {
            #expect(!policy.shouldRetry(error, isIdempotent: false))
        }
    }

    @Test("An idempotent POST can be retried")
    func retriesIdempotentPost() {
        let policy = NetworkRetryPolicy()
        #expect(policy.shouldRetry(.serverError(.status(503)), isIdempotent: true))
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
            #expect(!policy.shouldRetry(error, isIdempotent: true), "\(error)")
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

    @Test("NetworkRetryPolicy conforms to Equatable")
    func equatable() {
        #expect(
            NetworkRetryPolicy.default == NetworkRetryPolicy(maxRetries: 2, backoff: NetworkRetryPolicy.defaultBackoff))
        #expect(NetworkRetryPolicy(maxRetries: 2) != NetworkRetryPolicy(maxRetries: 3))
    }

    @Test("The retry policy is off by default")
    func offByDefault() {
        #expect(NetworkClientConfiguration().retryPolicy == nil)
    }
}
