import SwiftyNetwork

extension MutationRetryPolicy {
    /// A policy that retries without waiting, for fast, deterministic tests.
    ///
    /// Uses the default transient-error classification and ignores any `Retry-After`
    /// the server sent, so a `429` never makes a test wait.
    ///
    /// - Parameter maxRetries: Retries after the first attempt. Defaults to 3.
    /// - Returns: A policy with ``BackoffPolicy/immediate`` backoff.
    public static func immediate(maxRetries: Int = 3) -> MutationRetryPolicy {
        MutationRetryPolicy(maxRetries: maxRetries, backoff: .immediate)
    }
}
