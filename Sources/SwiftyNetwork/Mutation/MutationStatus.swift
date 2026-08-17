import Foundation

/// The lifecycle state of a mutation tracked by ``MutationQueue``.
///
/// Reflects only the network-execution outcome. UI concerns like optimistic
/// rollback stay app-side -- ``MutationQueue`` reports what happened, it
/// doesn't manage view state.
public enum MutationStatus: Sendable, Equatable {
    /// Enqueued and waiting to execute, or waiting behind an in-flight retry backoff.
    case pending

    /// A previous attempt failed with a transient error and is being retried.
    ///
    /// - Parameter attempt: The 1-based number of the retry attempt about to run.
    case retrying(attempt: Int)

    /// The mutation executed successfully and was removed from the queue.
    case succeeded

    /// The mutation failed permanently -- either a non-retryable error, or
    /// retries were exhausted -- and was removed from the queue.
    ///
    /// - Parameter reason: A description of the terminal failure.
    case failed(MutationFailureReason)
}

/// A `Sendable`, `Equatable` snapshot of the error that permanently failed a mutation.
///
/// Wraps an arbitrary `Error` (which is neither `Sendable` nor `Equatable`)
/// so it can travel through ``MutationStatus`` and be compared in tests,
/// mirroring how `NetworkClient` wraps foreign errors internally.
public struct MutationFailureReason: Sendable, Equatable, CustomStringConvertible {
    public let description: String

    /// Captures a description of the given error.
    ///
    /// - Parameter error: The error that caused the mutation to fail permanently.
    public init(_ error: any Error) {
        self.description = String(describing: error)
    }
}
