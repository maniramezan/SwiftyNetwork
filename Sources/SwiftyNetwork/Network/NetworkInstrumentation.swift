import Foundation

// MARK: - Instrumentation Protocol

/// A hook for observing ``NetworkClient`` request lifecycles, without
/// SwiftyNetwork depending on any particular observability SDK.
///
/// Implement this to feed request timing, retries, and outcomes into your
/// own instrumentation -- most notably OpenTelemetry, but any tracing or
/// metrics system works the same way. SwiftyNetwork does not take a
/// dependency on the OpenTelemetry SDK itself; this protocol is the seam an
/// app-side adapter plugs into.
///
/// Every event for a single logical `request(_:...)` call shares the same
/// ``NetworkRequestAttempt/requestID``, including across a 401-triggered
/// auth-refresh retry (a new attempt, same `requestID`). Use that to
/// correlate a parent span across attempts, and `attempt` to open a child
/// span per HTTP round trip:
///
/// ```swift
/// final class OTelNetworkInstrumentation: NetworkInstrumentation {
///     func requestStarted(_ event: NetworkRequestAttempt) async {
///         // Start (or continue, if event.attempt > 1) a span keyed by event.requestID.
///     }
///     func requestRetried(_ event: NetworkRequestAttempt) async {
///         // Record a retry event on the parent span.
///     }
///     func requestCompleted(_ event: NetworkRequestCompletion) async {
///         // End the span for event.requestID, setting status code + duration.
///     }
///     func requestFailed(_ event: NetworkRequestFailure) async {
///         // Record the error on the span and end it.
///     }
/// }
///
/// let client = NetworkClient(
///     configuration: NetworkClientConfiguration(instrumentation: OTelNetworkInstrumentation())
/// )
/// ```
///
/// Trace-context propagation (e.g. injecting a `traceparent` header) is not
/// this protocol's job -- it's already possible via ``NetworkEndpoint/headers``,
/// fully under the caller's control.
///
/// All methods have a no-op default, so a conformer only needs to implement
/// the events it cares about. Methods are `async` but not `throws`:
/// instrumentation must never fail a request.
public protocol NetworkInstrumentation: Sendable {
    /// Called when an HTTP attempt begins (the first attempt, or a retry
    /// after a successful auth refresh).
    func requestStarted(_ event: NetworkRequestAttempt) async

    /// Called after a successful auth refresh, immediately before retrying
    /// the request with new credentials -- distinct from ``requestStarted(_:)``
    /// so an adapter can record "why" a new attempt is happening.
    func requestRetried(_ event: NetworkRequestAttempt) async

    /// Called when an attempt completes with an HTTP response (any status
    /// code SwiftyNetwork doesn't itself turn into a thrown error, i.e. `2xx`).
    func requestCompleted(_ event: NetworkRequestCompletion) async

    /// Called when an attempt terminates with a thrown ``NetworkError`` --
    /// a transport failure, a non-2xx status, or a decoding failure.
    func requestFailed(_ event: NetworkRequestFailure) async
}

extension NetworkInstrumentation {
    public func requestStarted(_ event: NetworkRequestAttempt) async {}
    public func requestRetried(_ event: NetworkRequestAttempt) async {}
    public func requestCompleted(_ event: NetworkRequestCompletion) async {}
    public func requestFailed(_ event: NetworkRequestFailure) async {}
}

// MARK: - Events

/// Identifies one HTTP attempt within a ``NetworkClient`` request.
///
/// Emitted for ``NetworkInstrumentation/requestStarted(_:)`` and
/// ``NetworkInstrumentation/requestRetried(_:)``.
public struct NetworkRequestAttempt: Sendable {
    /// Identifies every attempt belonging to the same logical `request(_:...)`
    /// call, including retries after a 401 auth refresh. Use this to
    /// correlate a parent span across attempts.
    public let requestID: UUID

    /// The resolved request URL.
    public let url: URL

    /// The HTTP method used for this attempt.
    public let method: HTTPMethod

    /// The 1-based attempt number: `1` for the first attempt, `2` for the
    /// first auth-refresh retry, and so on.
    public let attempt: Int

    public init(requestID: UUID, url: URL, method: HTTPMethod, attempt: Int) {
        self.requestID = requestID
        self.url = url
        self.method = method
        self.attempt = attempt
    }
}

/// Describes an HTTP attempt that completed with a response.
///
/// Emitted for ``NetworkInstrumentation/requestCompleted(_:)``.
public struct NetworkRequestCompletion: Sendable {
    /// See ``NetworkRequestAttempt/requestID``.
    public let requestID: UUID

    /// The resolved request URL.
    public let url: URL

    /// The HTTP method used for this attempt.
    public let method: HTTPMethod

    /// See ``NetworkRequestAttempt/attempt``.
    public let attempt: Int

    /// The HTTP status code returned.
    public let statusCode: Int

    /// Wall-clock time from just before the network call to receiving the response.
    public let duration: TimeInterval

    public init(requestID: UUID, url: URL, method: HTTPMethod, attempt: Int, statusCode: Int, duration: TimeInterval) {
        self.requestID = requestID
        self.url = url
        self.method = method
        self.attempt = attempt
        self.statusCode = statusCode
        self.duration = duration
    }
}

/// Describes an HTTP attempt that terminated with a thrown ``NetworkError``.
///
/// Emitted for ``NetworkInstrumentation/requestFailed(_:)``.
public struct NetworkRequestFailure: Sendable {
    /// See ``NetworkRequestAttempt/requestID``.
    public let requestID: UUID

    /// The resolved request URL.
    public let url: URL

    /// The HTTP method used for this attempt.
    public let method: HTTPMethod

    /// See ``NetworkRequestAttempt/attempt``.
    public let attempt: Int

    /// Wall-clock time from just before the network call to the failure being observed.
    public let duration: TimeInterval

    /// The error that terminated this attempt. Use ``NetworkError/classification``
    /// for a stable category to tag onto a span attribute.
    public let error: NetworkError

    public init(
        requestID: UUID, url: URL, method: HTTPMethod, attempt: Int, duration: TimeInterval, error: NetworkError
    ) {
        self.requestID = requestID
        self.url = url
        self.method = method
        self.attempt = attempt
        self.duration = duration
        self.error = error
    }
}
