import Foundation

// MARK: - Single-Flight Cache

/// A cache decorator that coalesces concurrent cache-miss fetches for the same key.
///
/// Wraps any ``Cache``-conforming type and adds ``value(forKey:maxAge:orFetch:)``: on a
/// miss, the first caller for a key runs `fetch` while every other concurrent
/// caller for that same key awaits the same in-flight `Task` instead of
/// triggering a duplicate fetch (e.g. a duplicate network request).
///
/// Storage operations are serialized across keys, including the final fetch commit. Explicit
/// writes and removals invalidate the affected flight, even if its fetch ignores
/// cancellation. Use this wrapper exclusively to mutate the underlying cache.
/// Wrapped cache methods must not call back into this wrapper. Different keys fetch concurrently,
/// but slow storage can delay otherwise unrelated cache operations; ``removeAll()`` waits for
/// running operations and holds back later ones.
/// A canceled caller does not cancel work shared with other callers; it observes
/// cancellation after the shared work finishes.
///
/// `SingleFlightCache` adds only deduplication -- size limits, eviction, and
/// persistence are entirely up to whatever ``Cache`` you wrap (e.g.
/// `InMemoryCache(maxSize:)` for LRU eviction, or your own disk cache).
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
    let operations = CacheOperationGate<CacheKey>()
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

    /// Reads the stored entry after preceding storage operations finish.
    public func entry(forKey key: CacheKey) async -> CacheEntry<Value>? {
        await operations.runExclusive { await self.wrapped.entry(forKey: key) }
    }

    /// Invalidates a pending fetch and stores an explicit entry.
    public func setEntry(_ entry: CacheEntry<Value>, forKey key: CacheKey) async {
        await operations.runExclusive {
            await self.invalidate(key)
            await self.wrapped.setEntry(entry, forKey: key)
        }
    }

    /// Cancels the current fetch and removes the stored value before returning.
    public func removeValue(forKey key: CacheKey) async {
        await operations.runExclusive {
            await self.invalidate(key)
            await self.wrapped.removeValue(forKey: key)
        }
    }

    /// Cancels all current fetches and clears storage before returning.
    public func removeAll() async {
        await operations.runExclusive {
            await self.invalidateAll()
            await self.wrapped.removeAll()
        }
    }

    private func invalidate(_ key: CacheKey) {
        inFlightFetches.removeValue(forKey: key)?.task.cancel()
    }

    private func invalidateAll() {
        for flight in inFlightFetches.values { flight.task.cancel() }
        inFlightFetches.removeAll()
    }

    // MARK: - Single-Flight Fetch

    /// Returns the cached value for `key`, or runs `fetch` on a miss or when the cached value is
    /// older than `maxAge`.
    ///
    /// Concurrent calls for the same `key` that arrive while a fetch is
    /// already in flight await that same fetch rather than starting their
    /// own -- the defining single-flight guarantee. A successful fetch is
    /// stored in the wrapped cache before being returned; a failed
    /// fetch is not cached, so the next call retries it.
    ///
    /// Example:
    /// ```swift
    /// let profile = try await cache.value(forKey: "profile", maxAge: .seconds(300)) {
    ///     try await client.request(ProfileEndpoint(), responseType: Profile.self)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - key: The cache key to look up or populate.
    ///   - maxAge: The oldest cached value to return, measured from ``CacheEntry/timestamp``.
    ///     An older value is replaced by a fresh fetch. Defaults to `nil`, which returns a
    ///     cached value of any age.
    ///   - fetch: Produces the value on a cache miss. Runs at most once per
    ///     concurrent burst of calls for `key`.
    /// - Returns: The cached or freshly fetched value.
    /// - Throws: The fetch error, or `CancellationError` if the caller is canceled
    ///   or a write/removal supersedes the fetch before it commits.
    public func value(
        forKey key: CacheKey,
        maxAge: Duration? = nil,
        orFetch fetch: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let lookup = await operations.runExclusive { await self.lookup(key, maxAge: maxAge, fetch: fetch) }
        let value: Value
        switch lookup {
        case .cached(let cached): value = cached
        case .flight(let flight): value = try await flight.task.value
        }
        try Task.checkCancellation()
        return value
    }

    // Called only while holding the key's gate, including across wrapped-cache awaits.
    private func lookup(
        _ key: CacheKey,
        maxAge: Duration?,
        fetch: @escaping @Sendable () async throws -> Value
    ) async -> Lookup {
        if let cached = await wrapped.entry(forKey: key), maxAge.map({ cached.age() <= $0 }) ?? true {
            return .cached(cached.value)
        }
        if let flight = inFlightFetches[key] { return .flight(flight) }
        let id = UUID()
        let task = Task<Value, any Error> {
            do {
                let value = try await fetch()
                try Task.checkCancellation()
                return try await self.operations.runExclusive { try await self.commit(value, key: key, id: id) }
            } catch {
                await self.operations.runExclusive { await self.clearFlight(key, id: id) }
                throw error
            }
        }
        let flight = Flight(id: id, task: task)
        inFlightFetches[key] = flight
        return .flight(flight)
    }

    private func commit(_ value: Value, key: CacheKey, id: UUID) async throws -> Value {
        guard inFlightFetches[key]?.id == id else { throw CancellationError() }
        await wrapped.setEntry(CacheEntry(value), forKey: key)
        clearFlight(key, id: id)
        return value
    }

    private func clearFlight(_ key: CacheKey, id: UUID) {
        if inFlightFetches[key]?.id == id { inFlightFetches[key] = nil }
    }
}
