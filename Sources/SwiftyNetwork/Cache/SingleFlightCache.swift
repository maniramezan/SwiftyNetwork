import Foundation

// MARK: - Single-Flight Cache

/// A cache decorator that coalesces concurrent cache-miss fetches for the same key.
///
/// Wraps any ``Cache``-conforming type and adds ``value(forKey:orFetch:)``: on a
/// miss, the first caller for a key runs `fetch` while every other concurrent
/// caller for that same key awaits the same in-flight `Task` instead of
/// triggering a duplicate fetch (e.g. a duplicate network request).
///
/// Storage operations are serialized, including the final fetch commit. Explicit
/// writes and removals invalidate the affected flight, even if its fetch ignores
/// cancellation. Use this wrapper exclusively to mutate the underlying cache.
/// Wrapped cache methods must not call back into this wrapper. Storage is queued
/// across all keys, so a slow custom store can delay otherwise unrelated reads.
/// A canceled caller does not cancel work shared with other callers; it observes
/// cancellation after the shared work finishes. Different keys fetch concurrently.
///
/// `SingleFlightCache` adds only deduplication -- size limits, eviction, and
/// persistence are entirely up to whatever ``Cache`` you wrap (e.g.
/// `InMemoryCache(maxSize:)` for LRU eviction, or your own `PersistentCache`).
///
/// Example:
/// ```swift
/// let cache = SingleFlightCache(InMemoryCache<Data>(maxSize: 100))
/// async let a = cache.value(forKey: key) { try await fetchFromNetwork() }
/// async let b = cache.value(forKey: key) { try await fetchFromNetwork() }
/// // Only one fetch actually runs; both calls receive its result.
/// let (first, second) = try await (a, b)
/// ```
public actor SingleFlightCache<Wrapped: Cache>: Cache {
    /// The type of value stored by the wrapped cache.
    public typealias Value = Wrapped.Value

    private let wrapped: Wrapped
    let operations = CacheOperationGate()
    private struct Flight: Sendable {
        let id: UUID
        let task: Task<Value, any Error>
    }
    private enum Lookup: Sendable {
        case cached(Value)
        case flight(Flight)
    }
    private var inFlightFetches: [CacheKey: Flight] = [:]

    /// Wraps an existing cache with single-flight fetch coalescing.
    ///
    /// - Parameter wrapped: The cache to delegate storage to.
    public init(_ wrapped: Wrapped) {
        self.wrapped = wrapped
    }

    // MARK: - Cache API

    /// Reads the stored value after preceding storage operations finish.
    public func value(forKey key: CacheKey) async -> Value? {
        await operations.run { await self.wrapped.value(forKey: key) }
    }

    /// Invalidates a pending fetch and stores an explicit value.
    public func setValue(_ value: Value, forKey key: CacheKey) async {
        await operations.run {
            await self.invalidate(key)
            await self.wrapped.setValue(value, forKey: key)
        }
    }

    /// Cancels the current fetch and removes the stored value before returning.
    public func removeValue(forKey key: CacheKey) async {
        await operations.run {
            await self.invalidate(key)
            await self.wrapped.removeValue(forKey: key)
        }
    }

    /// Cancels all current fetches and clears storage before returning.
    public func removeAll() async {
        await operations.run {
            await self.invalidateAll()
            await self.wrapped.removeAll()
        }
    }

    /// Reads the timestamp after preceding storage operations finish.
    public func timestamp(forKey key: CacheKey) async -> Date? {
        await operations.run { await self.wrapped.timestamp(forKey: key) }
    }

    private func invalidate(_ key: CacheKey) {
        inFlightFetches.removeValue(forKey: key)?.task.cancel()
    }

    private func invalidateAll() {
        for flight in inFlightFetches.values { flight.task.cancel() }
        inFlightFetches.removeAll()
    }

    // MARK: - Single-Flight Fetch

    /// Returns the cached value for `key`, or runs `fetch` on a miss.
    ///
    /// Concurrent calls for the same `key` that arrive while a fetch is
    /// already in flight await that same fetch rather than starting their
    /// own -- the defining single-flight guarantee. A successful fetch is
    /// stored via ``setValue(_:forKey:)`` before being returned; a failed
    /// fetch is not cached, so the next call retries it.
    ///
    /// - Parameters:
    ///   - key: The cache key to look up or populate.
    ///   - fetch: Produces the value on a cache miss. Runs at most once per
    ///     concurrent burst of calls for `key`.
    /// - Returns: The cached or freshly fetched value.
    /// - Throws: The fetch error, or `CancellationError` if the caller is canceled
    ///   or a write/removal supersedes the fetch before it commits.
    public func value(forKey key: CacheKey, orFetch fetch: @escaping @Sendable () async throws -> Value) async throws
        -> Value
    {
        try Task.checkCancellation()
        let lookup = await operations.run { await self.lookup(key, fetch: fetch) }
        let value: Value
        switch lookup {
        case .cached(let cached): value = cached
        case .flight(let flight): value = try await flight.task.value
        }
        try Task.checkCancellation()
        return value
    }

    // Called only while holding operations, including across wrapped-cache awaits.
    private func lookup(_ key: CacheKey, fetch: @escaping @Sendable () async throws -> Value) async -> Lookup {
        if let cached = await wrapped.value(forKey: key) { return .cached(cached) }
        if let flight = inFlightFetches[key] { return .flight(flight) }
        let id = UUID()
        let task = Task<Value, any Error> {
            do {
                let value = try await fetch()
                try Task.checkCancellation()
                return try await self.operations.run { try await self.commit(value, key: key, id: id) }
            } catch {
                await self.operations.run { await self.clearFlight(key, id: id) }
                throw error
            }
        }
        let flight = Flight(id: id, task: task)
        inFlightFetches[key] = flight
        return .flight(flight)
    }

    private func commit(_ value: Value, key: CacheKey, id: UUID) async throws -> Value {
        guard inFlightFetches[key]?.id == id else { throw CancellationError() }
        await wrapped.setValue(value, forKey: key)
        clearFlight(key, id: id)
        return value
    }

    private func clearFlight(_ key: CacheKey, id: UUID) {
        if inFlightFetches[key]?.id == id { inFlightFetches[key] = nil }
    }
}
