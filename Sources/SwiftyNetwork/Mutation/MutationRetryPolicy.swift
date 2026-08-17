import Foundation

/// Governs whether and how long ``MutationQueue`` waits before retrying a
/// failed mutation.
///
/// ``NetworkClient`` deliberately does not retry transient network or 5xx
/// errors -- that's a per-call decision the caller has to make (see its
/// configuration docs). `MutationRetryPolicy` is that dedicated retry loop
/// for the mutation queue: exponential backoff with jitter, bounded by
/// ``maxAttempts`` and ``maxDelay``.
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
    /// how many attempts have elapsed.
    public var maxDelay: TimeInterval

    /// The multiplicative jitter range applied to the computed delay, to
    /// avoid many queued clients retrying in lockstep.
    public var jitterRange: ClosedRange<Double>

    /// Decides whether a given error is worth retrying at all.
    ///
    /// Defaults to retrying only errors that look transient: timeouts, no
    /// connectivity, malformed responses, and 5xx server errors. Client
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
    ///   - isRetryable: Predicate deciding whether an error should be retried.
    ///     Defaults to ``defaultIsRetryable(_:)``.
    public init(
        maxAttempts: Int = 5,
        baseDelay: TimeInterval = 1,
        maxDelay: TimeInterval = 60,
        jitterRange: ClosedRange<Double> = 0.5...1.5,
        isRetryable: @escaping @Sendable (any Error) -> Bool = MutationRetryPolicy.defaultIsRetryable
    ) {
        self.maxAttempts = max(0, maxAttempts)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(self.baseDelay, maxDelay)
        self.jitterRange = jitterRange
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
    ///   responses, and 5xx server errors; `false` for everything else,
    ///   including non-``NetworkError`` errors.
    public static func defaultIsRetryable(_ error: any Error) -> Bool {
        (error as? NetworkError)?.isTransient ?? false
    }

    /// Computes the backoff delay before a given retry attempt.
    ///
    /// - Parameters:
    ///   - attempt: The 1-based retry attempt number about to run.
    ///   - jitterGenerator: Produces a value in `0...1` used to sample within
    ///     ``jitterRange``. Overridable for deterministic tests; defaults to
    ///     `Double.random(in: 0...1)`.
    /// - Returns: The delay in seconds, already capped at ``maxDelay``.
    public func delay(
        forAttempt attempt: Int,
        jitterGenerator: @Sendable () -> Double = { Double.random(in: 0...1) }
    ) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        let uncapped = baseDelay * pow(2, exponent)
        let capped = min(uncapped, maxDelay)
        let jitterSpan = jitterRange.upperBound - jitterRange.lowerBound
        let multiplier = jitterRange.lowerBound + jitterGenerator() * jitterSpan
        return capped * multiplier
    }
}
