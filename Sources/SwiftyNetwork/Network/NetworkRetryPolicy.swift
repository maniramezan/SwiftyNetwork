import Foundation
import SwiftCommons

/// An opt-in policy that makes ``NetworkClient`` retry transient failures of
/// idempotent requests.
///
/// The policy is **off by default**; assign one to
/// ``NetworkClientConfiguration/retryPolicy`` to enable it. When enabled:
///
/// - Only idempotent methods are retried (``retryableMethods``: `GET`, `HEAD`,
///   `PUT`, `DELETE`). `POST` and `PATCH` are never replayed, not even on a
///   `429`, so a request that may have been processed is never duplicated.
/// - Retried failures are `429` (``NetworkError/tooManyRequests(_:)``),
///   5xx (``NetworkError/serverError(_:)``), timeouts
///   (``NetworkError/timeout(_:)``) and lost connectivity
///   (``NetworkError/noInternetConnection``). Everything else, including
///   decoding failures and other 4xx responses, is reported immediately.
/// - Waits use jittered exponential backoff capped at ``maxDelay``. When a
///   `429` or `503` carries `Retry-After`, the client waits at least that long, bounded
///   by ``maxRetryAfter`` so a huge value cannot park a request.
/// - At most ``maxRetries`` retries follow the first attempt.
/// - Waits are cancellation-aware: cancelling the calling task ends the wait
///   and the request throws `CancellationError`.
///
/// This is separate from authorization refresh
/// (``NetworkClientConfiguration/maxAuthRefreshAttempts``), which has its own
/// budget. It is also separate from ``MutationRetryPolicy``; avoid enabling
/// both on the client behind a ``MutationQueue`` unless you want the attempts
/// to multiply.
///
/// Example:
/// ```swift
/// let configuration = NetworkClientConfiguration(
///     retryPolicy: NetworkRetryPolicy(maxRetries: 3, baseDelay: 0.5, maxDelay: 8)
/// )
/// let client = NetworkClient(configuration: configuration)
/// ```
public struct NetworkRetryPolicy: Sendable {
    /// The HTTP methods that are safe to replay: `GET`, `HEAD`, `PUT` and `DELETE`.
    public static let retryableMethods: Set<HTTPMethod> = [.get, .head, .put, .delete]

    /// Maximum number of retries after the first attempt. `0` disables retrying.
    public var maxRetries: Int

    /// The backoff before the first retry, in seconds. Each later retry doubles
    /// the previous value until ``maxDelay`` caps it.
    public var baseDelay: Duration

    /// The upper bound on the computed backoff, in seconds, after jitter.
    public var maxDelay: Duration

    /// The multiplicative jitter range applied to the computed backoff, to keep
    /// many clients from retrying in lockstep.
    public var jitterRange: ClosedRange<Double>

    /// The upper bound on how long a server-supplied `Retry-After` is honored, in seconds.
    ///
    /// A larger value is clamped to this bound rather than ignored.
    public var maxRetryAfter: Duration

    /// A conservative default: 2 retries, 0.5s base delay doubling up to 8s,
    /// ±50% jitter, and `Retry-After` honored up to 30s.
    public static let `default` = NetworkRetryPolicy()

    /// Creates a retry policy.
    ///
    /// - Parameters:
    ///   - maxRetries: Maximum retries after the first attempt. Defaults to 2.
    ///   - baseDelay: Backoff before the first retry, in seconds. Defaults to 0.5.
    ///   - maxDelay: Upper bound on the backoff, in seconds. Defaults to 8.
    ///   - jitterRange: Multiplicative jitter range. Defaults to `0.5...1.5`.
    ///   - maxRetryAfter: Upper bound on an honored `Retry-After`, in seconds. Defaults to 30.
    public init(
        maxRetries: Int = 2,
        baseDelay: Duration = .milliseconds(500),
        maxDelay: Duration = .seconds(8),
        jitterRange: ClosedRange<Double> = 0.5...1.5,
        maxRetryAfter: Duration = .seconds(30)
    ) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelay = max(.zero, baseDelay)
        self.maxDelay = max(self.baseDelay, maxDelay)
        self.jitterRange = jitterRange
        self.maxRetryAfter = max(.zero, maxRetryAfter)
    }

    /// Whether a failed request should be retried, ignoring the attempt budget.
    ///
    /// - Parameters:
    ///   - error: The failure of the attempt that just ran.
    ///   - method: The HTTP method of the request.
    /// - Returns: `true` only for an idempotent ``retryableMethods`` request whose
    ///   failure is ``NetworkError/isTransient`` other than a malformed response:
    ///   `429`, a 5xx status, a timeout, or lost connectivity.
    public func shouldRetry(_ error: NetworkError, method: HTTPMethod) -> Bool {
        guard Self.retryableMethods.contains(method) else { return false }
        // Derived from NetworkError.isTransient so the two rules cannot drift.
        // A malformed response is the one transient case excluded: for an
        // idempotent request it usually signals a broken server or proxy,
        // not a condition a replay will fix.
        return error.isTransient && error.classification != .invalidResponse
    }

    /// Computes how long to wait before a retry.
    ///
    /// - Parameters:
    ///   - retry: The 1-based retry about to run.
    ///   - error: The failure that triggered the retry. A `429` or `503` with
    ///     `Retry-After` makes the delay at least that long, clamped to ``maxRetryAfter``.
    ///   - jitterGenerator: Produces a value in `0...1` sampled within ``jitterRange``.
    ///     Overridable for deterministic tests.
    /// - Returns: The delay in seconds.
    public func delay(
        forRetry retry: Int,
        after error: NetworkError? = nil,
        jitterGenerator: @Sendable () -> Double = { Double.random(in: 0...1) }
    ) -> Duration {
        let jitter = max(0, jitterRange.lowerBound)...max(0, jitterRange.upperBound)
        let backoff = withoutActuallyEscaping(jitterGenerator) { jitterSource in
            let delay =
                RetryBackoff.exponential(
                    baseDelay: baseDelay,
                    maxDelay: maxDelay,
                    jitter: jitter,
                    jitterSource: jitterSource
                )
                .delay(forRetry: retry)
            return min(max(.zero, delay), maxDelay)
        }
        return RetryAfter.delay(backoff: backoff, retryAfter: error?.retryAfter, cap: maxRetryAfter)
    }
}

extension RetryAfter {
    /// Combines a computed backoff with a server-supplied `Retry-After`.
    ///
    /// - Parameters:
    ///   - backoff: The policy's own backoff.
    ///   - retryAfter: The server's requested wait, if any.
    ///   - cap: The longest `retryAfter` that is honored.
    /// - Returns: `backoff` without a `Retry-After`; otherwise the larger of
    ///   `backoff` and `retryAfter` clamped to `cap`.
    static func delay(backoff: Duration, retryAfter: Duration?, cap: Duration) -> Duration {
        guard let retryAfter else { return backoff }
        return max(backoff, min(retryAfter, cap))
    }
}
