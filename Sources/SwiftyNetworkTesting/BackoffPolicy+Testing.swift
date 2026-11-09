import SwiftyNetwork

extension BackoffPolicy {
    /// A zero-delay backoff that also ignores `Retry-After`, so retries run immediately in tests.
    public static let immediate = BackoffPolicy(
        baseDelay: .zero,
        maxDelay: .zero,
        jitterRange: 1...1,
        maxRetryAfter: .zero
    )
}
