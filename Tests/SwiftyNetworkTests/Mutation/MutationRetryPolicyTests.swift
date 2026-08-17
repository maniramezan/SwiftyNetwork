import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("MutationRetryPolicy Tests")
struct MutationRetryPolicyTests {

    @Test("Delay grows exponentially with attempt number, before jitter")
    func delayGrowsExponentially() {
        let policy = MutationRetryPolicy(maxAttempts: 10, baseDelay: 1, maxDelay: 1000, jitterRange: 1...1)

        #expect(policy.delay(forAttempt: 1) == 1)
        #expect(policy.delay(forAttempt: 2) == 2)
        #expect(policy.delay(forAttempt: 3) == 4)
        #expect(policy.delay(forAttempt: 4) == 8)
    }

    @Test("Delay is capped at maxDelay")
    func delayIsCapped() {
        let policy = MutationRetryPolicy(maxAttempts: 20, baseDelay: 1, maxDelay: 10, jitterRange: 1...1)

        #expect(policy.delay(forAttempt: 10) == 10)
    }

    @Test("Jitter scales the delay within jitterRange")
    func jitterScalesDelay() {
        let policy = MutationRetryPolicy(maxAttempts: 5, baseDelay: 10, maxDelay: 100, jitterRange: 0.5...1.5)

        #expect(policy.delay(forAttempt: 1, jitterGenerator: { 0 }) == 5)
        #expect(policy.delay(forAttempt: 1, jitterGenerator: { 1 }) == 15)
        #expect(policy.delay(forAttempt: 1, jitterGenerator: { 0.5 }) == 10)
    }

    @Test("Default policy retries timeouts, missing connectivity, invalid responses, and 5xx errors")
    func defaultRetriesTransientErrors() {
        #expect(MutationRetryPolicy.defaultIsRetryable(NetworkError.timeout))
        #expect(MutationRetryPolicy.defaultIsRetryable(NetworkError.noInternetConnection))
        #expect(MutationRetryPolicy.defaultIsRetryable(NetworkError.invalidResponse))
        #expect(MutationRetryPolicy.defaultIsRetryable(NetworkError.serverError(statusCode: 500, data: nil)))
        #expect(MutationRetryPolicy.defaultIsRetryable(NetworkError.serverError(statusCode: 503, data: nil)))
    }

    @Test("Default policy does not retry client errors, encoding failures, or unknown errors")
    func defaultDoesNotRetryNonTransientErrors() {
        #expect(!MutationRetryPolicy.defaultIsRetryable(NetworkError.unauthorized))
        #expect(!MutationRetryPolicy.defaultIsRetryable(NetworkError.forbidden))
        #expect(!MutationRetryPolicy.defaultIsRetryable(NetworkError.notFound))
        #expect(!MutationRetryPolicy.defaultIsRetryable(NetworkError.serverError(statusCode: 400, data: nil)))
        #expect(!MutationRetryPolicy.defaultIsRetryable(NetworkError.invalidURL(url: "bad")))
        #expect(!MutationRetryPolicy.defaultIsRetryable(URLError(.badURL)))
    }

    @Test("defaultIsRetryable delegates to NetworkError.isTransient, the shared classification source of truth")
    func defaultIsRetryableDelegatesToNetworkErrorIsTransient() {
        let errors: [NetworkError] = [
            .timeout,
            .noInternetConnection,
            .invalidResponse,
            .serverError(statusCode: 500, data: nil),
            .serverError(statusCode: 400, data: nil),
            .unauthorized,
            .forbidden,
            .notFound,
            .invalidURL(url: "bad"),
        ]
        for error in errors {
            #expect(MutationRetryPolicy.defaultIsRetryable(error) == error.isTransient)
        }
    }

    @Test("maxAttempts and baseDelay are clamped to non-negative values")
    func negativeValuesAreClamped() {
        let policy = MutationRetryPolicy(maxAttempts: -1, baseDelay: -5, maxDelay: -10)

        #expect(policy.maxAttempts == 0)
        #expect(policy.baseDelay == 0)
        #expect(policy.maxDelay == 0)
    }
}
