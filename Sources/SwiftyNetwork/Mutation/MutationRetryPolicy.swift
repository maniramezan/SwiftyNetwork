import Foundation

/// Governs whether and how long ``MutationQueue`` waits before retrying a
/// failed mutation.
///
/// ``NetworkClient`` does not retry transient failures unless you opt in with
/// ``NetworkClientConfiguration/retryPolicy`` (idempotent requests only).
/// `MutationRetryPolicy` is the dedicated retry loop for the mutation queue,
/// which also replays non-idempotent requests. It has the same shape as
/// ``NetworkRetryPolicy``: at most ``maxRetries`` retries after the first
/// attempt, waits from a ``BackoffPolicy`` that honors `Retry-After` on a `429`
/// or `503`, and ``shouldRetry(_:)`` to decide which failures are retried.
///
/// Example:
/// ```swift
/// let policy = MutationRetryPolicy(maxRetries: 5)
/// let queue = MutationQueue(client: NetworkClient.shared, retryPolicy: policy)
/// ```
public struct MutationRetryPolicy: Sendable {
    /// The default backoff: 1s doubling up to 60s, ±50% jitter, and `Retry-After` honored up to 300s.
    public static let defaultBackoff = BackoffPolicy(
        baseDelay: .seconds(1),
        maxDelay: .seconds(60),
        maxRetryAfter: .seconds(300)
    )

    /// The maximum number of retries after the first attempt before a mutation
    /// is reported ``MutationStatus/failed(_:)``, so a mutation is sent at most
    /// `maxRetries + 1` times.
    public var maxRetries: Int

    /// How long to wait before each retry.
    public var backoff: BackoffPolicy

    /// Decides whether an error is worth retrying at all. Read through ``shouldRetry(_:)``.
    ///
    /// Defaults to ``defaultShouldRetry(_:)``.
    public var retryPredicate: @Sendable (any Error) -> Bool

    /// A general-purpose default: 5 retries with ``defaultBackoff``.
    public static let `default` = MutationRetryPolicy()

    /// Creates a retry policy.
    ///
    /// - Parameters:
    ///   - maxRetries: Retries after the first attempt. Negative values are clamped to `0`. Defaults to 5.
    ///   - backoff: How long to wait before each retry. Defaults to ``defaultBackoff``.
    ///   - shouldRetry: Decides whether an error is worth retrying. Defaults to
    ///     ``defaultShouldRetry(_:)``.
    public init(
        maxRetries: Int = 5,
        backoff: BackoffPolicy = MutationRetryPolicy.defaultBackoff,
        shouldRetry: @escaping @Sendable (any Error) -> Bool = MutationRetryPolicy.defaultShouldRetry
    ) {
        self.maxRetries = max(0, maxRetries)
        self.backoff = backoff
        self.retryPredicate = shouldRetry
    }

    /// Whether a failed mutation should be retried.
    ///
    /// - Parameter error: The error thrown by the mutation's network call.
    /// - Returns: The result of ``retryPredicate``.
    public func shouldRetry(_ error: any Error) -> Bool {
        retryPredicate(error)
    }

    /// The default retry rule: retry only errors that look transient.
    ///
    /// Delegates to ``NetworkError/isTransient``, the single source of truth
    /// for transient-error classification shared across the package (retry
    /// policies and telemetry code alike).
    ///
    /// - Parameter error: The error thrown by the mutation's network call.
    /// - Returns: `true` for timeouts, missing connectivity, `429` rate limiting, and 5xx
    ///   server errors; `false` for everything else, including 4xx client errors, a
    ///   response that is not HTTP, and non-``NetworkError`` errors.
    public static func defaultShouldRetry(_ error: any Error) -> Bool {
        (error as? NetworkError)?.isTransient ?? false
    }

    /// Computes how long to wait before a retry.
    ///
    /// - Parameters:
    ///   - retry: The 1-based retry about to run.
    ///   - error: The failure that triggered the retry. A ``NetworkError/retryAfter``, if any,
    ///     sets a floor on the wait (see ``BackoffPolicy/delay(forRetry:retryAfter:jitterGenerator:)``).
    ///   - jitterGenerator: Produces a value in `0...1` sampled within ``BackoffPolicy/jitterRange``.
    ///     Overridable for deterministic tests.
    /// - Returns: The wait before the retry.
    public func delay(
        forRetry retry: Int,
        after error: (any Error)? = nil,
        jitterGenerator: @Sendable () -> Double = { Double.random(in: 0...1) }
    ) -> Duration {
        backoff.delay(
            forRetry: retry,
            retryAfter: (error as? NetworkError)?.retryAfter,
            jitterGenerator: jitterGenerator
        )
    }
}
