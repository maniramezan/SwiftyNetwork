import SwiftyNetwork

extension NetworkRetryPolicy {
    /// A policy that retries without waiting, for fast, deterministic tests.
    ///
    /// Uses the standard retry classification (idempotent methods only) but never
    /// waits, ignoring any `Retry-After` the server sent.
    ///
    /// - Parameter maxRetries: Retries after the first attempt. Defaults to 2.
    /// - Returns: A policy with ``BackoffPolicy/immediate`` backoff.
    public static func immediate(maxRetries: Int = 2) -> NetworkRetryPolicy {
        NetworkRetryPolicy(maxRetries: maxRetries, backoff: .immediate)
    }
}
