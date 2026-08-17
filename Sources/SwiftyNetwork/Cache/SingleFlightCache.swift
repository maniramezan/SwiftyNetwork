import Foundation

// MARK: - Single-Flight Cache

/// A cache decorator that coalesces concurrent cache-miss fetches for the same key.
///
/// Wraps any ``Cache``-conforming type and adds ``value(forKey:orFetch:)``: on a
/// miss, the first caller for a key runs `fetch` while every other concurrent
/// caller for that same key awaits the same in-flight `Task` instead of
/// triggering a duplicate fetch (e.g. a duplicate network request). Plain
/// ``Cache`` operations (`value(forKey:)`, `setValue`, `removeValue`,
/// `removeAll`, `timestamp(forKey:)`) pass straight through to the wrapped
/// cache and are unaffected by in-flight coalescing.
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
    private var inFlightFetches: [CacheKey: Task<Value, any Error>] = [:]

    /// Wraps an existing cache with single-flight fetch coalescing.
    ///
    /// - Parameter wrapped: The cache to delegate storage to.
    public init(_ wrapped: Wrapped) {
        self.wrapped = wrapped
    }

    // MARK: - Cache API (pass-through)

    public func value(forKey key: CacheKey) async -> Value? {
        await wrapped.value(forKey: key)
    }

    public func setValue(_ value: Value, forKey key: CacheKey) async {
        await wrapped.setValue(value, forKey: key)
    }

    public func removeValue(forKey key: CacheKey) async {
        await wrapped.removeValue(forKey: key)
        inFlightFetches[key]?.cancel()
        inFlightFetches[key] = nil
    }

    public func removeAll() async {
        await wrapped.removeAll()
        for task in inFlightFetches.values {
            task.cancel()
        }
        inFlightFetches.removeAll()
    }

    public func timestamp(forKey key: CacheKey) async -> Date? {
        await wrapped.timestamp(forKey: key)
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
    /// - Throws: Whatever `fetch` throws, if the fetch fails.
    public func value(forKey key: CacheKey, orFetch fetch: @escaping @Sendable () async throws -> Value) async throws
        -> Value
    {
        if let cached = await wrapped.value(forKey: key) {
            return cached
        }

        if let inFlight = inFlightFetches[key] {
            return try await inFlight.value
        }

        let task = Task<Value, any Error> {
            try await fetch()
        }
        inFlightFetches[key] = task

        do {
            let value = try await task.value
            inFlightFetches[key] = nil
            await wrapped.setValue(value, forKey: key)
            return value
        } catch {
            inFlightFetches[key] = nil
            throw error
        }
    }
}
