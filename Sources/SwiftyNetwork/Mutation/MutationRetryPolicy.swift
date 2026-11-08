import Foundation
import SwiftCommons

/// Governs whether and how long ``MutationQueue`` waits before retrying a
/// failed mutation.
///
/// ``NetworkClient`` does not retry transient failures unless you opt in with
/// ``NetworkClientConfiguration/retryPolicy`` (idempotent requests only).
/// `MutationRetryPolicy` is the dedicated retry loop for the mutation queue,
/// which also replays non-idempotent requests: exponential backoff with
/// jitter, bounded by ``maxAttempts`` and ``maxDelay``. A `429` or `503` response with
/// a `Retry-After` header makes the queue wait at least that long, bounded by
/// ``maxRetryAfter``.
///
/// Example:
/// ```swift
/// let policy = MutationRetryPolicy(maxAttempts: 5, baseDelay: 1, maxDelay: 60)
/// let queue = MutationQueue(client: NetworkClient.shared, retryPolicy: policy)
/// ```
public struct MutationRetryPolicy: Sendable {
    /// Maximum number of retry attempts after the initial failure before a
    /// mutation is reported ``MutationStatus/failed(_:)``.
    public var maxAttempts: Int

    /// The delay before the first retry, in seconds. Each subsequent retry
    /// doubles the previous delay until ``maxDelay`` caps it.
    public var baseDelay: TimeInterval

    /// The upper bound on delay between retries, in seconds, regardless of
    /// how many attempts have elapsed or how jitter scales the delay.
    public var maxDelay: TimeInterval

    /// The multiplicative jitter range applied to the computed delay, to
    /// avoid many queued clients retrying in lockstep.
    public var jitterRange: ClosedRange<Double>

    /// The upper bound on how long a server-supplied `Retry-After` is honored, in seconds.
    ///
    /// Applies to ``NetworkError/tooManyRequests(retryAfter:data:response:)``. This is
    /// the one deliberate exception to ``maxDelay``: a mutation hitting `429`
    /// waits as long as the server asked, up to this bound, rather than
    /// retrying early and being throttled again.
    public var maxRetryAfter: TimeInterval

    /// Decides whether a given error is worth retrying at all.
    ///
    /// Defaults to retrying only errors that look transient: timeouts, no
    /// connectivity, malformed responses, `429` rate limiting, and 5xx server errors. Client
    /// errors (4xx other than what `NetworkClient` already handles via auth
    /// refresh), encoding/decoding failures, and invalid URLs are not
    /// retried since a retry can't change their outcome.
    public var isRetryable: @Sendable (any Error) -> Bool

    /// A reasonable general-purpose default: 5 attempts, 1s base delay
    /// doubling up to a 60s cap, with ±50% jitter.
    public static let `default` = MutationRetryPolicy()

    /// Creates a retry policy.
    ///
    /// - Parameters:
    ///   - maxAttempts: Maximum retry attempts after the initial failure. Defaults to 5.
    ///   - baseDelay: Delay before the first retry, in seconds. Defaults to 1.
    ///   - maxDelay: Upper bound on retry delay, in seconds. Defaults to 60.
    ///   - jitterRange: Multiplicative jitter range applied to the computed delay. Defaults to `0.5...1.5`.
    ///   - maxRetryAfter: Upper bound on an honored `Retry-After`, in seconds. Defaults to 300.
    ///   - isRetryable: Predicate deciding whether an error should be retried.
    ///     Defaults to ``defaultIsRetryable(_:)``.
    public init(
        maxAttempts: Int = 5,
        baseDelay: TimeInterval = 1,
        maxDelay: TimeInterval = 60,
        jitterRange: ClosedRange<Double> = 0.5...1.5,
        maxRetryAfter: TimeInterval = 300,
        isRetryable: @escaping @Sendable (any Error) -> Bool = MutationRetryPolicy.defaultIsRetryable
    ) {
        self.maxAttempts = max(0, maxAttempts)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(self.baseDelay, maxDelay)
        self.jitterRange = jitterRange
        self.maxRetryAfter = max(0, maxRetryAfter)
        self.isRetryable = isRetryable
    }

    /// The default transient-error classifier used by ``default``.
    ///
    /// Delegates to ``NetworkError/isTransient``, the single source of truth
    /// for transient-error classification shared across the package (retry
    /// policies and telemetry code alike).
    ///
    /// - Parameter error: The error thrown by the mutation's network call.
    /// - Returns: `true` for timeouts, missing connectivity, malformed
    ///   responses, `429` rate limiting, and 5xx server errors; `false` for everything else,
    ///   including non-``NetworkError`` errors.
    public static func defaultIsRetryable(_ error: any Error) -> Bool {
        (error as? NetworkError)?.isTransient ?? false
    }

    /// Computes the wait before a retry attempt.
    ///
    /// The result is the jittered exponential backoff, capped at ``maxDelay``.
    /// When `error` carries a `Retry-After` (``NetworkError/tooManyRequests(retryAfter:data:response:)``
    /// or a `503` ``NetworkError/serverError(statusCode:data:retryAfter:response:)``), the result
    /// is at least that long, clamped to ``maxRetryAfter``.
    ///
    /// - Parameters:
    ///   - attempt: The 1-based retry attempt number about to run.
    ///   - error: The failure that triggered the retry, if any. Pass `nil` for the plain backoff.
    ///   - jitterGenerator: Produces a value in `0...1` used to sample within
    ///     ``jitterRange``. Overridable for deterministic tests; defaults to
    ///     `Double.random(in: 0...1)`.
    /// - Returns: The delay in seconds.
    public func delay(
        forAttempt attempt: Int,
        after error: (any Error)? = nil,
        jitterGenerator: @Sendable () -> Double = { Double.random(in: 0...1) }
    ) -> TimeInterval {
        // Negative multipliers can't produce a meaningful delay; clamp so the
        // shared backoff's non-negative jitter requirement always holds.
        let jitter = max(0, jitterRange.lowerBound)...max(0, jitterRange.upperBound)
        let backoff = withoutActuallyEscaping(jitterGenerator) { jitterSource in
            let delay = RetryBackoff.exponential(
                baseDelay: .seconds(baseDelay),
                maxDelay: .seconds(maxDelay),
                jitter: jitter,
                jitterSource: jitterSource
            )
            .delay(forRetry: attempt)
            .timeInterval
            // Preserve the queue's hard cap after jitter as well as before it.
            return min(max(0, delay), maxDelay)
        }
        return RetryAfter.delay(
            backoff: backoff,
            retryAfter: (error as? NetworkError)?.retryAfter,
            cap: maxRetryAfter
        )
    }
}
