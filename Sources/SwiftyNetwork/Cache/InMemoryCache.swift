import Foundation

// MARK: - In-Memory Cache Implementation

/// A lightweight, in-memory cache with timestamp tracking.
///
/// Use this cache to store short-lived values in memory. The cache is implemented
/// as an `actor` which means all operations are serialized and thread-safe by
/// default when accessed across concurrency domains.
///
/// Notes:
/// - Values are stored in memory only and are not persisted to disk.
/// - Each stored value contains a timestamp that can be used to determine staleness.
/// - This implementation is intentionally small and performant for common use cases.
///
/// Example:
/// ```swift
/// let cache = InMemoryCache<User>()
/// await cache.setValue(user, forKey: CacheKey("user:123"))
/// let cached = await cache.value(forKey: CacheKey("user:123"))
/// ```
public actor InMemoryCache<T: Sendable>: Cache {
    
    /// Internal storage entry that contains the value and the time it was stored.
    private struct CacheEntry {
        let value: T
        let timestamp: Date
    }
    
    // Underlying storage dictionary. Access is protected by actor isolation.
    private var storage = [CacheKey: CacheEntry]()

    /// Creates an empty in-memory cache.
    public init() {}

    // MARK: - Cache API

    /// Retrieves a value for the given cache key, if present.
    /// - Parameter key: The cache key.
    /// - Returns: The stored value, or `nil` if not found.
    public func value(forKey key: CacheKey) async -> T? {
        storage[key]?.value
    }

    /// Stores a value for the given cache key and records the current timestamp.
    /// - Parameters:
    ///   - value: The value to store.
    ///   - key: The cache key.
    public func setValue(_ value: T, forKey key: CacheKey) async {
        storage[key] = CacheEntry(value: value, timestamp: Date())
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
}
