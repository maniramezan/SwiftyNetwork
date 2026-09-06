/// Serializes compound storage operations across suspension points.
///
/// Callers must not recursively enter the same gate. Cancellation does not skip
/// queued storage mutations: an invalidation must complete before it returns.
/// Network fetches must run outside the gate so invalidation can cancel them.
actor CacheOperationGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Internal diagnostic used to observe queue admission in concurrency tests.
    var queuedOperationCount: Int { waiters.count }

    func run<Result: Sendable>(
        _ operation: @Sendable () async throws -> Result
    ) async rethrows -> Result {
        if occupied {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            occupied = true
        }
        defer {
            if waiters.isEmpty {
                occupied = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        return try await operation()
    }
}
