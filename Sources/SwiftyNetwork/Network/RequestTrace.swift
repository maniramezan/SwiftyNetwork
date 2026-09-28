import Foundation

/// Reports one HTTP attempt's lifecycle to an optional ``NetworkInstrumentation``.
///
/// Captures the identifiers shared by every event of an attempt and the
/// monotonic start instant, so the request pipeline reports outcomes with a
/// single call instead of rebuilding event values at each exit point.
struct RequestTrace: Sendable {
    let instrumentation: (any NetworkInstrumentation)?
    let requestID: UUID
    let url: URL
    let method: HTTPMethod
    let attempt: Int
    /// Reset by ``start()``; exposed only so the memberwise initializer can default it.
    var startedAt: ContinuousClock.Instant = .now

    /// Emits `requestStarted`, then starts the duration clock so the callback
    /// itself is excluded from the measured duration.
    mutating func start() async {
        await instrumentation?.requestStarted(
            NetworkRequestAttempt(requestID: requestID, url: url, method: method, attempt: attempt)
        )
        startedAt = .now
    }

    func completed(statusCode: Int) async {
        await instrumentation?.requestCompleted(
            NetworkRequestCompletion(
                requestID: requestID,
                url: url,
                method: method,
                attempt: attempt,
                statusCode: statusCode,
                duration: elapsed
            )
        )
    }

    func failed(_ error: NetworkError) async {
        await instrumentation?.requestFailed(
            NetworkRequestFailure(
                requestID: requestID,
                url: url,
                method: method,
                attempt: attempt,
                duration: elapsed,
                error: error
            )
        )
    }

    /// Emits `requestRetried` for the attempt that follows this one.
    func retrying() async {
        await instrumentation?.requestRetried(
            NetworkRequestAttempt(requestID: requestID, url: url, method: method, attempt: attempt + 1)
        )
    }

    /// Monotonic seconds since ``start()``; unaffected by wall-clock corrections.
    private var elapsed: TimeInterval {
        let components = startedAt.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
