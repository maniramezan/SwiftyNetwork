import Foundation
internal import SwiftCommons

// MARK: - In-Memory Cache Implementation

/// A lightweight, in-memory cache with timestamp tracking and optional size limits.
///
/// Use this cache to store short-lived values in memory. The cache is implemented
/// as an `actor` which means all operations are serialized and thread-safe by
/// default when accessed across concurrency domains.
///
/// Notes:
/// - Values are stored in memory only and are not persisted to disk.
/// - Each stored value contains a timestamp that can be used to determine staleness.
/// - Optional LRU eviction when a maximum entry count and/or a maximum total
///   cost (for example bytes) is specified.
/// - This implementation is intentionally small and performant for common use cases.
///
/// Example:
/// ```swift
/// let cache = InMemoryCache<User>(maxSize: 100)
/// await cache.setValue(user, forKey: CacheKey("user:123"))
/// let cached = await cache.value(forKey: CacheKey("user:123"))
///
/// // Bound raw bytes rather than entry count.
/// let images = InMemoryCache<Data>(maxBytes: 50 * 1024 * 1024)
/// ```
public actor InMemoryCache<T: Sendable>: Cache {

    /// Internal storage slot: the cached entry and its cost.
    private struct Slot {
        let entry: CacheEntry<T>
        let cost: Int
    }

    /// Entries in least-recently-used order. Access is protected by actor isolation.
    private var storage = LRUStorage<CacheKey, Slot>()

    /// Maximum number of entries allowed in the cache. When exceeded, least recently used entries are evicted.
    private let maxSize: Int?

    /// Maximum total cost across all entries, or `nil` for no cost limit.
    private let maxCost: Int?

    /// Computes an entry's cost; `nil` when no cost limit is configured.
    private let cost: (@Sendable (T) -> Int)?

    /// Sum of the costs of all stored entries.
    private var currentCost = 0

    /// Creates an empty in-memory cache.
    ///
    /// Example:
    /// ```swift
    /// let unlimitedCache = InMemoryCache<User>()
    /// let boundedCache = InMemoryCache<User>(maxSize: 100)
    /// ```
    ///
    /// - Parameter maxSize: Optional maximum number of entries. When exceeded, LRU eviction occurs.
    ///   Negative values are treated as `0`.
    public init(maxSize: Int? = nil) {
        self.maxSize = maxSize.map { max(0, $0) }
        self.maxCost = nil
        self.cost = nil
    }

    /// Creates an empty in-memory cache bounded by total cost, and optionally by entry count.
    ///
    /// Each value's cost is computed once, when it is stored. When the total
    /// exceeds `maxCost`, least recently used entries are evicted until it
    /// fits. A single value costlier than `maxCost` is evicted immediately.
    ///
    /// Example:
    /// ```swift
    /// let thumbnails = InMemoryCache<Thumbnail>(maxCost: 20_000_000) { $0.pixelData.count }
    /// ```
    ///
    /// - Parameters:
    ///   - maxSize: Optional maximum number of entries. Negative values are treated as `0`.
    ///   - maxCost: Maximum total cost across all entries. Negative values are treated as `0`.
    ///   - cost: Returns the cost of a value, for example its size in bytes.
    ///     Negative costs are treated as `0`.
    public init(maxSize: Int? = nil, maxCost: Int, cost: @escaping @Sendable (T) -> Int) {
        self.maxSize = maxSize.map { max(0, $0) }
        self.maxCost = max(0, maxCost)
        self.cost = cost
    }

    // MARK: - Cache API

    /// Retrieves the entry for the given cache key, if present.
    ///
    /// Accessing an entry marks it as most recently used for LRU eviction.
    ///
    /// - Parameter key: The cache key.
    /// - Returns: The stored value and its timestamp, or `nil` if not found.
    public func entry(forKey key: CacheKey) async -> CacheEntry<T>? {
        storage.value(forKey: key)?.entry
    }

    /// Stores an entry for the given cache key, keeping its timestamp.
    ///
    /// If this write exceeds `maxSize` or `maxCost`, least recently used
    /// entries are evicted.
    ///
    /// - Parameters:
    ///   - entry: The value and timestamp to store.
    ///   - key: The cache key.
    public func setEntry(_ entry: CacheEntry<T>, forKey key: CacheKey) async {
        store(entry, forKey: key)
    }

    /// Removes the value associated with the given key.
    /// - Parameter key: The cache key to remove.
    public func removeValue(forKey key: CacheKey) async {
        if let removed = storage.removeValue(forKey: key) {
            currentCost -= removed.cost
        }
    }

    /// Removes all values from the cache.
    public func removeAll() async {
        storage.removeAll()
        currentCost = 0
    }

    // MARK: - Expiration Helpers

    /// Removes entries stored at least `maxAge` ago.
    ///
    /// Example:
    /// ```swift
    /// await cache.removeEntries(olderThan: .seconds(300))
    /// ```
    ///
    /// - Parameter maxAge: Age threshold. Entries this old or older are removed.
    public func removeEntries(olderThan maxAge: Duration) async {
        let cutoff = Date().addingTimeInterval(-maxAge.timeInterval)
        let removed = storage.removeAll { $0.entry.timestamp <= cutoff }
        currentCost -= removed.reduce(0) { $0 + $1.cost }
    }

    /// Returns the number of entries currently stored in the cache.
    ///
    /// Example:
    /// ```swift
    /// let currentSize = await cache.count()
    /// ```
    public func count() async -> Int {
        storage.count
    }

    /// Returns the total cost of all stored entries.
    ///
    /// Always `0` for caches created without a cost function.
    ///
    /// Example:
    /// ```swift
    /// let bytesInUse = await imageCache.totalCost()
    /// ```
    public func totalCost() async -> Int {
        currentCost
    }

    // MARK: - Private Helpers

    private func store(_ entry: CacheEntry<T>, forKey key: CacheKey) {
        let entryCost = cost.map { max(0, $0(entry.value)) } ?? 0
        if let replaced = storage.removeValue(forKey: key) {
            currentCost -= replaced.cost
        }
        if let maxCost {
            // Make room before adding: summing two valid costs can overflow Int.
            while entryCost > maxCost - currentCost,
                let evicted = storage.removeLeastRecentlyUsed()
            {
                currentCost -= evicted.value.cost
                Logger.debug("Evicted LRU cache entry to stay within limits", category: .cache)
            }
            guard entryCost <= maxCost else { return }
        }
        storage.setValue(Slot(entry: entry, cost: entryCost), forKey: key)
        currentCost += entryCost
        evictLRUIfNeeded()
    }

    /// Evicts least recently used entries until the cache fits its entry-count and cost limits.
    private func evictLRUIfNeeded() {
        while exceedsLimits, let evicted = storage.removeLeastRecentlyUsed() {
            currentCost -= evicted.value.cost
            Logger.debug("Evicted LRU cache entry to stay within limits", category: .cache)
        }
    }

    private var exceedsLimits: Bool {
        if let maxSize, storage.count > maxSize { return true }
        if let maxCost, currentCost > maxCost { return true }
        return false
    }
}

// MARK: - Byte-Limited Data Cache

extension InMemoryCache where T == Data {
    /// Creates a cache for raw bytes bounded by their total size.
    ///
    /// Use this with ``RemoteDataCache`` to keep image or file caches within a
    /// memory budget regardless of how many entries they hold.
    ///
    /// Example:
    /// ```swift
    /// let images = RemoteDataCache(cache: InMemoryCache<Data>(maxBytes: 50 * 1024 * 1024))
    /// ```
    ///
    /// - Parameters:
    ///   - maxSize: Optional maximum number of entries.
    ///   - maxBytes: Maximum total size of all stored values, in bytes.
    public init(maxSize: Int? = nil, maxBytes: Int) {
        self.init(maxSize: maxSize, maxCost: maxBytes, cost: { $0.count })
    }
}
