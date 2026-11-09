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

    @Test("Upward jitter never pushes the delay past maxDelay")
    func jitterNeverExceedsMaxDelay() {
        let policy = MutationRetryPolicy(maxAttempts: 20, baseDelay: 1, maxDelay: 10, jitterRange: 0.5...1.5)

        #expect(policy.delay(forAttempt: 10, jitterGenerator: { 1 }) == 10)
        #expect(policy.delay(forAttempt: 10, jitterGenerator: { 0 }) == 5)
    }

    @Test("Default policy retries timeouts, missing connectivity, invalid responses, and 5xx errors")
    func defaultRetriesTransientErrors() {
        #expect(MutationRetryPolicy.defaultIsRetryable(NetworkError.timeout(nil)))
        #expect(MutationRetryPolicy.defaultIsRetryable(NetworkError.noInternetConnection))
        #expect(MutationRetryPolicy.defaultIsRetryable(NetworkError.invalidResponse))
        #expect(MutationRetryPolicy.defaultIsRetryable(NetworkError.serverError(.status(500))))
        #expect(MutationRetryPolicy.defaultIsRetryable(NetworkError.serverError(.status(503))))
        #expect(MutationRetryPolicy.defaultIsRetryable(NetworkError.tooManyRequests(.status(429, retryAfter: 5))))
        #expect(MutationRetryPolicy.defaultIsRetryable(NetworkError.tooManyRequests(.status(429))))
    }

    @Test("Default policy does not retry client errors, encoding failures, or unknown errors")
    func defaultDoesNotRetryNonTransientErrors() {
        #expect(!MutationRetryPolicy.defaultIsRetryable(NetworkError.unauthorized(.status(401))))
        #expect(!MutationRetryPolicy.defaultIsRetryable(NetworkError.forbidden(.status(403))))
        #expect(!MutationRetryPolicy.defaultIsRetryable(NetworkError.notFound(.status(404))))
        #expect(!MutationRetryPolicy.defaultIsRetryable(NetworkError.clientError(.status(400))))
        #expect(!MutationRetryPolicy.defaultIsRetryable(NetworkError.invalidURL(url: "bad")))
        #expect(!MutationRetryPolicy.defaultIsRetryable(URLError(.badURL)))
    }

    @Test("defaultIsRetryable delegates to NetworkError.isTransient, the shared classification source of truth")
    func defaultIsRetryableDelegatesToNetworkErrorIsTransient() {
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

    @Test("A 429 Retry-After longer than the backoff sets the delay")
    func retryAfterOverridesShorterBackoff() {
        let policy = MutationRetryPolicy(baseDelay: 1, maxDelay: 4, jitterRange: 1...1)
        let error = NetworkError.tooManyRequests(.status(429, retryAfter: 20))

        #expect(policy.delay(forAttempt: 1, after: error) == 20)
    }

    @Test("A 429 Retry-After is clamped to maxRetryAfter, not maxDelay")
    func retryAfterIsClampedToMaxRetryAfter() {
        let policy = MutationRetryPolicy(baseDelay: 1, maxDelay: 4, jitterRange: 1...1, maxRetryAfter: 30)

        #expect(policy.delay(forAttempt: 1, after: NetworkError.tooManyRequests(.status(429, retryAfter: 600))) == 30)
        #expect(policy.delay(forAttempt: 1, after: NetworkError.tooManyRequests(.status(429, retryAfter: 10))) == 10)
    }

    @Test("A 503 Retry-After sets the delay like a 429 does")
    func serviceUnavailableRetryAfterSetsDelay() {
        let policy = MutationRetryPolicy(baseDelay: 1, maxDelay: 4, jitterRange: 1...1, maxRetryAfter: 30)

        #expect(
            policy.delay(forAttempt: 1, after: NetworkError.serverError(.status(503, retryAfter: 20)))
                == 20
        )
        #expect(
            policy.delay(forAttempt: 1, after: NetworkError.serverError(.status(503, retryAfter: 600)))
                == 30
        )
    }

    @Test("A Retry-After shorter than the backoff never shortens the backoff")
    func retryAfterNeverShortensBackoff() {
        let policy = MutationRetryPolicy(baseDelay: 8, maxDelay: 8, jitterRange: 1...1)
        let error = NetworkError.tooManyRequests(.status(429, retryAfter: 1))

        #expect(policy.delay(forAttempt: 1, after: error) == 8)
    }

    @Test("Errors without Retry-After use the plain backoff")
    func errorsWithoutRetryAfterUseBackoff() {
        let policy = MutationRetryPolicy(baseDelay: 2, maxDelay: 60, jitterRange: 1...1)

        #expect(policy.delay(forAttempt: 1, after: NetworkError.tooManyRequests(.status(429))) == 2)
        #expect(policy.delay(forAttempt: 1, after: NetworkError.serverError(.status(503))) == 2)
        #expect(policy.delay(forAttempt: 2, after: URLError(.timedOut)) == 4)
    }

    @Test("maxRetryAfter is clamped to a non-negative value")
    func negativeMaxRetryAfterIsClamped() {
        #expect(MutationRetryPolicy(maxRetryAfter: -1).maxRetryAfter == 0)
    }
}
