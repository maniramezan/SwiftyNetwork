import SwiftyNetwork

extension NetworkRetryPolicy {
    /// A policy that retries without waiting, for fast, deterministic tests.
    ///
    /// Uses the standard retry classification (idempotent methods only) but never
    /// waits, ignoring any `Retry-After` the server sent.
    ///
    /// - Parameter maxRetries: Maximum retries after the first attempt. Defaults to 2.
    /// - Returns: A policy with zero backoff, no jitter, and no `Retry-After` wait.
    public static func immediate(maxRetries: Int = 2) -> NetworkRetryPolicy {
        NetworkRetryPolicy(
            maxRetries: maxRetries,
            baseDelay: 0,
            maxDelay: 0,
            jitterRange: 1...1,
            maxRetryAfter: 0
        )
    }
}
