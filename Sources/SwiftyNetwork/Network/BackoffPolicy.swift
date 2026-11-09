import Foundation
internal import SwiftCommons

/// Jittered exponential backoff shared by ``NetworkRetryPolicy`` and ``MutationRetryPolicy``.
///
/// The wait before retry *n* is ``baseDelay`` doubled *n − 1* times, scaled by a
/// random factor from ``jitterRange``, and capped at ``maxDelay``. When the failure
/// carries a server `Retry-After`, the wait is at least that long, bounded by
/// ``maxRetryAfter`` so a huge value cannot park a request.
///
/// Example:
/// ```swift
/// let backoff = BackoffPolicy(baseDelay: .milliseconds(500), maxDelay: .seconds(8), maxRetryAfter: .seconds(30))
/// let policy = NetworkRetryPolicy(maxRetries: 3, backoff: backoff)
/// ```
public struct BackoffPolicy: Sendable, Equatable {
    /// The wait before the first retry. Each later retry doubles it until ``maxDelay`` caps it.
    public var baseDelay: Duration

    /// The upper bound on the computed backoff, after jitter.
    public var maxDelay: Duration

    /// The multiplicative jitter range applied to the computed backoff, so many
    /// clients do not retry in lockstep. Negative bounds are treated as `0`.
    public var jitterRange: ClosedRange<Double>

    /// The upper bound on how long a server-supplied `Retry-After` is honored.
    ///
    /// The one deliberate exception to ``maxDelay``: a `429` or `503` waits as long
    /// as the server asked, up to this bound, rather than retrying early and being
    /// throttled again.
    public var maxRetryAfter: Duration

    /// Creates a backoff policy.
    ///
    /// Negative durations are clamped to `.zero`, and `maxDelay` is raised to at least `baseDelay`.
    ///
    /// - Parameters:
    ///   - baseDelay: The wait before the first retry.
    ///   - maxDelay: The upper bound on the computed backoff.
    ///   - jitterRange: The multiplicative jitter range. Defaults to `0.5...1.5` (±50%).
    ///   - maxRetryAfter: The upper bound on an honored `Retry-After`.
    public init(
        baseDelay: Duration,
        maxDelay: Duration,
        jitterRange: ClosedRange<Double> = 0.5...1.5,
        maxRetryAfter: Duration
    ) {
        self.baseDelay = max(.zero, baseDelay)
        self.maxDelay = max(self.baseDelay, maxDelay)
        self.jitterRange = jitterRange
        self.maxRetryAfter = max(.zero, maxRetryAfter)
    }

    /// Computes the wait before a retry.
    ///
    /// - Parameters:
    ///   - retry: The 1-based retry about to run.
    ///   - retryAfter: The server-requested wait, if the failure carried one.
    ///   - jitterGenerator: Produces a value in `0...1` used to sample within ``jitterRange``.
    ///     Overridable for deterministic tests; defaults to `Double.random(in: 0...1)`.
    /// - Returns: The jittered backoff capped at ``maxDelay``, or, with a `retryAfter`, the
    ///   larger of that backoff and `retryAfter` clamped to ``maxRetryAfter``.
    public func delay(
        forRetry retry: Int,
        retryAfter: Duration? = nil,
        jitterGenerator: @Sendable () -> Double = { Double.random(in: 0...1) }
    ) -> Duration {
        // Negative multipliers can't produce a meaningful delay; clamp so the
        // shared backoff's non-negative jitter requirement always holds.
        let jitter = max(0, jitterRange.lowerBound)...max(0, jitterRange.upperBound)
        let backoff = withoutActuallyEscaping(jitterGenerator) { jitterSource in
            let delay = RetryBackoff.exponential(
                baseDelay: baseDelay,
                maxDelay: maxDelay,
                jitter: jitter,
                jitterSource: jitterSource
            )
            .delay(forRetry: retry)
            // Keep the hard cap after jitter as well as before it.
            return min(max(.zero, delay), maxDelay)
        }
        guard let retryAfter else { return backoff }
        return max(backoff, min(retryAfter, maxRetryAfter))
    }
}
