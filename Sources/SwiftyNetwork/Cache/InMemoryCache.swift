import Foundation

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
/// - Optional LRU eviction when a maximum size is specified.
/// - This implementation is intentionally small and performant for common use cases.
///
/// Example:
/// ```swift
/// let cache = InMemoryCache<User>(maxSize: 100)
/// await cache.setValue(user, forKey: CacheKey("user:123"))
/// let cached = await cache.value(forKey: CacheKey("user:123"))
/// ```
public actor InMemoryCache<T: Sendable>: TimestampedCache {

    /// Internal storage entry that contains the value and the time it was stored.
    private struct CacheEntry {
        let value: T
        let timestamp: Date
    }

    /// Entries in least-recently-used order. Access is protected by actor isolation.
    private var storage = LRUStorage<CacheKey, CacheEntry>()

    /// Maximum number of entries allowed in the cache. When exceeded, least recently used entries are evicted.
    private let maxSize: Int?

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
    }

    // MARK: - Cache API

    /// Retrieves a value for the given cache key, if present.
    ///
    /// Accessing a value marks it as most recently used for LRU eviction.
    ///
    /// - Parameter key: The cache key.
    /// - Returns: The stored value, or `nil` if not found.
    public func value(forKey key: CacheKey) async -> T? {
        storage.value(forKey: key)?.value
    }

    /// Stores a value for the given cache key and records the current timestamp.
    ///
    /// If the cache has a `maxSize` and this write exceeds it, the least recently
    /// used entry is evicted.
    ///
    /// - Parameters:
    ///   - value: The value to store.
    ///   - key: The cache key.
    public func setValue(_ value: T, forKey key: CacheKey) async {
        storage.setValue(CacheEntry(value: value, timestamp: Date()), forKey: key)
        evictLRUIfNeeded()
    }

    /// Stores a value for the given cache key with an explicit timestamp.
    ///
    /// Use this when restoring values from persistence or preserving timestamps
    /// during cache promotion.
    ///
    /// - Parameters:
    ///   - value: The value to store.
    ///   - key: The cache key.
    ///   - timestamp: The timestamp to record for the cached value.
    public func setValue(_ value: T, forKey key: CacheKey, timestamp: Date) async {
        storage.setValue(CacheEntry(value: value, timestamp: timestamp), forKey: key)
        evictLRUIfNeeded()
    }

    /// Removes the value associated with the given key.
    /// - Parameter key: The cache key to remove.
    public func removeValue(forKey key: CacheKey) async {
        storage.removeValue(forKey: key)
    }

    /// Removes all values from the cache.
    public func removeAll() async {
        storage.removeAll()
    }

    /// Returns the timestamp when the value for the given key was stored.
    /// - Parameter key: The cache key to inspect.
    /// - Returns: The cache timestamp, or `nil` if there is no value for the key.
    public func timestamp(forKey key: CacheKey) async -> Date? {
        storage.peekValue(forKey: key)?.timestamp
    }

    // MARK: - Expiration Helpers

    /// Removes entries older than `maxAge` seconds.
    ///
    /// Example:
    /// ```swift
    /// await cache.removeExpiredEntries(maxAge: 300)
    /// ```
    ///
    /// - Parameter maxAge: Maximum allowed age in seconds. Entries older than this will be removed.
    public func removeExpiredEntries(maxAge: TimeInterval) async {
        let cutoff = Date().addingTimeInterval(-maxAge)
        storage.removeAll { $0.timestamp <= cutoff }
    }

    /// Convenience alias to match common naming: removes items older than the supplied age.
    ///
    /// Example:
    /// ```swift
    /// await cache.removeEntries(olderThan: 60)
    /// ```
    ///
    /// - Parameter maxAge: Age threshold in seconds. Items older than this are removed.
    public func removeEntries(olderThan maxAge: TimeInterval) async {
        await removeExpiredEntries(maxAge: maxAge)
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

    // MARK: - Private Helpers

    /// Evicts least recently used entries until the cache fits within its maximum size.
    private func evictLRUIfNeeded() {
        guard let maxSize else { return }
        while storage.count > maxSize, storage.removeLeastRecentlyUsed() != nil {
            Logger.debug("Evicted LRU cache entry to stay within limit (\(maxSize))", category: .cache)
        }
    }
}
