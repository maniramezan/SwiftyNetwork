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

    /// Internal storage entry that contains the value, timestamp, and last access time.
    private struct CacheEntry {
        let value: T
        let timestamp: Date
        var lastAccessed: Date
    }

    // Underlying storage dictionary. Access is protected by actor isolation.
    private var storage = [CacheKey: CacheEntry]()

    /// Maximum number of entries allowed in the cache. When exceeded, least recently used entries are evicted.
    private let maxSize: Int?

    /// Creates an empty in-memory cache.
    /// - Parameter maxSize: Optional maximum number of entries. When exceeded, LRU eviction occurs.
    public init(maxSize: Int? = nil) {
        self.maxSize = maxSize
    }

    // MARK: - Cache API

    /// Retrieves a value for the given cache key, if present.
    /// - Parameter key: The cache key.
    /// - Returns: The stored value, or `nil` if not found.
    public func value(forKey key: CacheKey) async -> T? {
        guard var entry = storage[key] else {
            return nil
        }
        // Update last accessed time for LRU tracking
        entry.lastAccessed = Date()
        storage[key] = entry
        return entry.value
    }

    /// Stores a value for the given cache key and records the current timestamp.
    /// - Parameters:
    ///   - value: The value to store.
    ///   - key: The cache key.
    public func setValue(_ value: T, forKey key: CacheKey) async {
        let now = Date()
        storage[key] = CacheEntry(value: value, timestamp: now, lastAccessed: now)
        await evictLRUIfNeeded()
    }

    /// Stores a value for the given cache key with an explicit timestamp.
    /// - Parameters:
    ///   - value: The value to store.
    ///   - key: The cache key.
    ///   - timestamp: The timestamp to record for the cached value.
    public func setValue(_ value: T, forKey key: CacheKey, timestamp: Date) async {
        let now = Date()
        storage[key] = CacheEntry(value: value, timestamp: timestamp, lastAccessed: now)
        await evictLRUIfNeeded()
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
        storage[key]?.timestamp
    }

    // MARK: - Expiration Helpers

    /// Removes entries older than `maxAge` seconds.
    /// - Parameter maxAge: Maximum allowed age in seconds. Entries older than this will be removed.
    public func removeExpiredEntries(maxAge: TimeInterval) async {
        let cutoff = Date().addingTimeInterval(-maxAge)
        storage = storage.filter { $0.value.timestamp > cutoff }
    }

    /// Convenience alias to match common naming: removes items older than the supplied age.
    /// - Parameter olderThan: Age threshold in seconds. Items older than this are removed.
    public func removeEntries(olderThan maxAge: TimeInterval) async {
        await removeExpiredEntries(maxAge: maxAge)
    }

    /// Returns the number of entries currently stored in the cache.
    public func count() async -> Int {
        storage.count
    }

    // MARK: - Private Helpers

    /// Evicts the least recently used entry if the cache exceeds its maximum size.
    private func evictLRUIfNeeded() async {
        guard let maxSize, storage.count > maxSize else {
            return
        }

        Logger.debug("Cache size (\(storage.count)) exceeds limit (\(maxSize)), evicting LRU entry")

        // Find the least recently used entry
        let lruKey = storage.min { a, b in
            a.value.lastAccessed < b.value.lastAccessed
        }?.key

        if let lruKey {
            storage.removeValue(forKey: lruKey)
            Logger.debug("Evicted LRU cache entry")
        }
    }
}
