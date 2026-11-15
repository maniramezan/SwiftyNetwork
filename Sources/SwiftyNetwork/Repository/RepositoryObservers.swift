import Foundation

/// Delivers the values a repository stores to the callers observing each cache key.
///
/// Each stream keeps only the newest value, so a slow consumer sees the current state rather
/// than a backlog.
actor RepositoryObservers<Value: Sendable> {
    private var continuations: [CacheKey: [UUID: AsyncStream<Value>.Continuation]] = [:]

    /// Internal diagnostic used to check that finished streams are unregistered.
    var observerCount: Int { continuations.values.reduce(0) { $0 + $1.count } }

    /// Returns a stream of the values published for `key` from now on.
    func stream(for key: CacheKey) -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        // Registered before returning, so a value published right after is not missed.
        continuations[key, default: [:]][id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.remove(id, for: key) }
        }
        return stream
    }

    func publish(_ value: Value, for key: CacheKey) {
        guard let observers = continuations[key] else { return }
        for continuation in observers.values {
            continuation.yield(value)
        }
    }

    private func remove(_ id: UUID, for key: CacheKey) {
        continuations[key]?[id] = nil
        if continuations[key]?.isEmpty == true {
            continuations[key] = nil
        }
    }
}
