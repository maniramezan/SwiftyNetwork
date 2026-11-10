import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("BackoffPolicy Tests")
struct BackoffPolicyTests {
    private func backoff(
        base: Duration = .seconds(1),
        max: Duration = .seconds(1000),
        jitter: ClosedRange<Double> = 1...1,
        retryAfterCap: Duration = .seconds(30)
    ) -> BackoffPolicy {
        BackoffPolicy(baseDelay: base, maxDelay: max, jitterRange: jitter, maxRetryAfter: retryAfterCap)
    }

    @Test("Delay doubles per retry before jitter")
    func delayGrowsExponentially() {
        let policy = backoff()

        #expect(policy.delay(forRetry: 1) == .seconds(1))
        #expect(policy.delay(forRetry: 2) == .seconds(2))
        #expect(policy.delay(forRetry: 3) == .seconds(4))
        #expect(policy.delay(forRetry: 4) == .seconds(8))
    }

    @Test("Delay is capped at maxDelay")
    func delayIsCapped() {
        #expect(backoff(max: .seconds(10)).delay(forRetry: 10) == .seconds(10))
    }

    @Test("Jitter scales the delay within jitterRange and never pushes it past maxDelay")
    func jitterStaysWithinBounds() {
        let policy = backoff(base: .seconds(10), max: .seconds(12), jitter: 0.5...1.5)

        #expect(policy.delay(forRetry: 1, jitterGenerator: { 0 }) == .seconds(5))
        #expect(policy.delay(forRetry: 1, jitterGenerator: { 0.5 }) == .seconds(10))
        #expect(policy.delay(forRetry: 1, jitterGenerator: { 1 }) == .seconds(12))
    }

    @Test("A Retry-After longer than the backoff sets the delay, clamped to maxRetryAfter")
    func retryAfterSetsFloorClampedToCap() {
        let policy = backoff(base: .seconds(1), max: .seconds(4), retryAfterCap: .seconds(30))

        #expect(policy.delay(forRetry: 1, retryAfter: .seconds(20)) == .seconds(20))
        #expect(policy.delay(forRetry: 1, retryAfter: .seconds(86_400)) == .seconds(30))
    }

    @Test("A Retry-After shorter than the backoff never shortens it")
    func retryAfterNeverShortensBackoff() {
        let policy = backoff(base: .seconds(8), max: .seconds(8))

        #expect(policy.delay(forRetry: 1, retryAfter: .seconds(1)) == .seconds(8))
        #expect(policy.delay(forRetry: 1, retryAfter: nil) == .seconds(8))
    }

    @Test("The initializer clamps negatives and keeps maxDelay at or above baseDelay")
    func initializerClampsValues() {
        let negative = BackoffPolicy(baseDelay: .seconds(-2), maxDelay: .seconds(-3), maxRetryAfter: .seconds(-4))
        #expect(negative.baseDelay == .zero)
        #expect(negative.maxDelay == .zero)
        #expect(negative.maxRetryAfter == .zero)

        let inverted = BackoffPolicy(baseDelay: .seconds(10), maxDelay: .seconds(2), maxRetryAfter: .zero)
        #expect(inverted.maxDelay == .seconds(10))

        let defaultRetryAfter = BackoffPolicy(baseDelay: .seconds(1), maxDelay: .seconds(10))
        #expect(defaultRetryAfter.maxRetryAfter == .seconds(60))
    }

    @Test("Both retry policies delegate their delay to the same backoff, including Retry-After")
    func policiesShareBackoff() {
        let shared = backoff(base: .seconds(2), max: .seconds(60))
        let network = NetworkRetryPolicy(maxRetries: 3, backoff: shared)
        let mutation = MutationRetryPolicy(maxRetries: 3, backoff: shared)
        let throttled = NetworkError.tooManyRequests(.status(429, retryAfter: 9))

        for retry in 1...3 {
            #expect(network.delay(forRetry: retry) == shared.delay(forRetry: retry))
            #expect(mutation.delay(forRetry: retry) == shared.delay(forRetry: retry))
        }
        #expect(network.delay(forRetry: 1, after: throttled) == .seconds(9))
        #expect(mutation.delay(forRetry: 1, after: throttled) == .seconds(9))
        #expect(mutation.delay(forRetry: 2, after: URLError(.timedOut)) == .seconds(4))
    }
}
