import SwiftyNetwork

/// Records every ``NetworkInstrumentation`` event for later assertions.
public actor NetworkInstrumentationRecorder: NetworkInstrumentation {
    /// Creates an empty recorder.
    public init() {}
    /// Recorded started events in delivery order.
    public private(set) var started: [NetworkRequestAttempt] = []
    /// Recorded retried events in delivery order.
    public private(set) var retried: [NetworkRequestAttempt] = []
    /// Recorded completed events in delivery order.
    public private(set) var completed: [NetworkRequestCompletion] = []
    /// Recorded failed events in delivery order.
    public private(set) var failed: [NetworkRequestFailure] = []

    /// Records the supplied instrumentation event.
    /// - Parameter event: The request lifecycle event.
    public func requestStarted(_ event: NetworkRequestAttempt) async { started.append(event) }
    /// Records the supplied instrumentation event.
    /// - Parameter event: The request lifecycle event.
    public func requestRetried(_ event: NetworkRequestAttempt) async { retried.append(event) }
    /// Records the supplied instrumentation event.
    /// - Parameter event: The request lifecycle event.
    public func requestCompleted(_ event: NetworkRequestCompletion) async { completed.append(event) }
    /// Records the supplied instrumentation event.
    /// - Parameter event: The request lifecycle event.
    public func requestFailed(_ event: NetworkRequestFailure) async { failed.append(event) }
}
