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
/// Switch on ``category`` to decide what to tell the user. It separates the cases a
/// UI must treat differently: the device was offline, the server rejected the request
/// (a `4xx`, so retrying it unchanged will not help), the server failed (a `5xx`), the
/// credentials expired, or the app cancelled the mutation. The HTTP ``response``, when
/// there is one, carries the status, headers, and body, for example an API error code.
///
/// Example:
/// ```swift
/// for await event in await queue.events() {
///     guard case .failed(let reason) = event.status else { continue }
///     switch reason.category {
///     case .cancelled:
///         break
///     case .offline, .timedOut:
///         showBanner("You're offline. Your like wasn't saved.")
///     case .rejected:
///         rollBackOptimisticLike()
///         showError(try? reason.response?.decodeBody(APIError.self))
///     case .unauthorized:
///         promptSignIn()
///     case .serverError, .other:
///         showBanner("Something went wrong. Try again later.")
///     }
/// }
/// ```
public struct MutationFailureReason: Sendable, Equatable, CustomStringConvertible {
    /// What kind of failure ended a mutation.
    public enum Category: Sendable, Equatable {
        /// ``MutationQueue/cancel(_:)`` or ``MutationQueue/cancelAll()`` ended the mutation.
        /// The request did not fail; don't show an error.
        case cancelled

        /// The device had no usable connection
        /// (``NetworkError/noInternetConnection``) on the last attempt.
        case offline

        /// The request timed out (``NetworkError/timeout(_:)``), at the transport layer
        /// or with a `408`. The server may or may not have processed it.
        case timedOut

        /// The server answered `401` and authorization could not be refreshed
        /// (``NetworkError/unauthorized(_:)`` or ``NetworkError/authorizationRefreshFailed(underlying:)``),
        /// or the provider had no authorization to send
        /// (``NetworkError/authorizationUnavailable(underlying:)``).
        case unauthorized

        /// The server rejected the request with a `4xx` status other than `401` and `408`,
        /// such as `400`, `403`, `404`, `409`, `422`, or `429` after retries ran out.
        /// Retrying the same request will not succeed; ``response`` has the details.
        case rejected

        /// The server failed with a `5xx` status.
        case serverError

        /// Any other failure: an invalid URL, an unexpected status, an encoding or
        /// decoding failure, or an error that is not a ``NetworkError``.
        case other
    }

    /// What kind of failure ended the mutation.
    public let category: Category

    /// The ``NetworkErrorClassification`` of the error, or `nil` when it was not a ``NetworkError``.
    public let classification: NetworkErrorClassification?

    /// The HTTP response that failed the mutation, or `nil` when it did not come from an HTTP status.
    public let response: HTTPResponse?

    /// A description of the underlying error.
    public let description: String

    /// `true` when the mutation ended because ``MutationQueue/cancel(_:)`` or
    /// ``MutationQueue/cancelAll()`` was called, not because the request failed.
    ///
    /// Check this before showing a failure message or rolling back an optimistic update.
    public var isCancellation: Bool {
        category == .cancelled
    }

    /// The HTTP status code that failed the mutation, or `nil` when it did not come from an HTTP status.
    public var statusCode: Int? {
        response?.statusCode
    }

    /// Whether the failure was transient (``NetworkError/isTransient``), meaning the queue
    /// gave up only because retries ran out. Enqueuing the mutation again later may succeed.
    public var isTransient: Bool {
        classification?.isTransient ?? false
    }

    /// Captures the given error.
    ///
    /// - Parameter error: The error that caused the mutation to fail permanently.
    public init(_ error: any Error) {
        self.description = String(describing: error)
        guard let networkError = error as? NetworkError else {
            self.category = error is CancellationError ? .cancelled : .other
            self.classification = nil
            self.response = nil
            return
        }
        self.classification = networkError.classification
        self.response = networkError.response
        self.category = Self.category(for: networkError)
    }

    private static func category(for error: NetworkError) -> Category {
        if case .underlying(let underlying) = error, underlying is CancellationError {
            return .cancelled
        }
        switch error.category {
        case .offline: return .offline
        case .timedOut: return .timedOut
        case .unauthorized: return .unauthorized
        case .rejected: return .rejected
        case .serverError: return .serverError
        case .other: return .other
        }
    }
}
