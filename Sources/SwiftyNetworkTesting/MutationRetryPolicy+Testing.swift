import SwiftyNetwork

extension MutationRetryPolicy {
    /// A policy that retries without waiting, for fast, deterministic tests.
    ///
    /// Uses the default transient-error classification and ignores any `Retry-After`
    /// the server sent, so a `429` never makes a test wait.
    ///
    /// - Parameter maxAttempts: Maximum retry attempts after the initial failure. Defaults to 3.
    /// - Returns: A policy with zero backoff and no jitter.
    public static func immediate(maxAttempts: Int = 3) -> MutationRetryPolicy {
        MutationRetryPolicy(
            maxAttempts: maxAttempts, baseDelay: .zero, maxDelay: .zero, jitterRange: 1...1, maxRetryAfter: .zero)
    }
}
