import Foundation

/// An opt-in policy that makes ``NetworkClient`` retry transient failures of
/// idempotent requests.
///
/// The policy is **off by default**; assign one to
/// ``NetworkClientConfiguration/retryPolicy`` to enable it. When enabled:
///
/// - Only idempotent requests are retried (``NetworkEndpoint/isIdempotent``, by default
///   `GET`, `HEAD`, `PUT`, `DELETE`, and `OPTIONS`). A `POST` or `PATCH` is not replayed,
///   not even on a `429`, so a request that may have been processed is never duplicated,
///   unless its endpoint declares itself idempotent.
/// - Retried failures are `429` (``NetworkError/tooManyRequests(_:)``),
///   5xx (``NetworkError/serverError(_:)``), timeouts
///   (``NetworkError/timeout(_:)``), lost connectivity
///   (``NetworkError/noInternetConnection``) and an unreachable server
///   (``NetworkError/serverUnreachable(_:)``). Everything else, including
///   decoding failures and other 4xx responses, is reported immediately.
/// - Waits follow ``backoff``, honoring `Retry-After` on a `429` or `503`.
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
///     retryPolicy: NetworkRetryPolicy(maxRetries: 3)
/// )
/// let client = NetworkClient(configuration: configuration)
/// ```
public struct NetworkRetryPolicy: Sendable, Equatable {
    /// The default backoff: 0.5s doubling up to 8s, ±50% jitter, and `Retry-After` honored up to 30s.
    public static let defaultBackoff = BackoffPolicy(
        baseDelay: .milliseconds(500),
        maxDelay: .seconds(8),
        maxRetryAfter: .seconds(30)
    )

    /// The maximum number of retries after the first attempt, so a request is
    /// sent at most `maxRetries + 1` times.
    public var maxRetries: Int

    /// How long to wait before each retry.
    public var backoff: BackoffPolicy

    /// A conservative default: 2 retries with ``defaultBackoff``.
    public static let `default` = NetworkRetryPolicy()

    /// Creates a retry policy.
    ///
    /// - Parameters:
    ///   - maxRetries: Retries after the first attempt. Negative values are clamped to `0`. Defaults to 2.
    ///   - backoff: How long to wait before each retry. Defaults to ``defaultBackoff``.
    public init(maxRetries: Int = 2, backoff: BackoffPolicy = NetworkRetryPolicy.defaultBackoff) {
        self.maxRetries = max(0, maxRetries)
        self.backoff = backoff
    }

    /// Whether a failed attempt should be retried.
    ///
    /// - Parameters:
    ///   - error: The failure of the attempt that just ran.
    ///   - isIdempotent: Whether the request is safe to send again, from
    ///     ``NetworkEndpoint/isIdempotent``.
    /// - Returns: `true` only for an idempotent request whose failure is
    ///   ``NetworkError/isTransient``: `429`, a 5xx status, a timeout, lost
    ///   connectivity, or an unreachable server.
    public func shouldRetry(_ error: NetworkError, isIdempotent: Bool) -> Bool {
        isIdempotent && error.isTransient
    }

    /// Computes how long to wait before a retry.
    ///
    /// - Parameters:
    ///   - retry: The 1-based retry about to run.
    ///   - error: The failure that triggered the retry. Its ``NetworkError/retryAfter``, if any,
    ///     sets a floor on the wait (see ``BackoffPolicy/delay(forRetry:retryAfter:jitterGenerator:)``).
    ///   - jitterGenerator: Produces a value in `0...1` sampled within ``BackoffPolicy/jitterRange``.
    ///     Overridable for deterministic tests.
    /// - Returns: The wait before the retry.
    public func delay(
        forRetry retry: Int,
        after error: NetworkError? = nil,
        jitterGenerator: @Sendable () -> Double = { Double.random(in: 0...1) }
    ) -> Duration {
        backoff.delay(forRetry: retry, retryAfter: error?.retryAfter, jitterGenerator: jitterGenerator)
    }
}
