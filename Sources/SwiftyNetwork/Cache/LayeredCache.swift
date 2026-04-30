import Foundation

// MARK: - Layered Cache

/// A cache that composes an in-memory layer with an optional persistent layer.
///
/// Reads consult the in-memory layer first, then fall back to the persistent layer.
/// Values loaded from the persistent layer are promoted into memory.
///
/// Example:
/// ```swift
/// let memory = InMemoryCache<User>(maxSize: 100)
/// let cache = LayeredCache(memoryCache: memory)
/// await cache.setValue(user, forKey: CacheKey.user("123", resource: "profile"))
/// ```
public actor LayeredCache<T: Sendable>: Cache {
    private let memoryCache: AnyCache<T>
    private let persistentCache: AnyCache<T>?
    private let setMemoryValueWithTimestamp: (@Sendable (T, CacheKey, Date) async -> Void)?

    /// Creates a layered cache with only a memory cache.
    ///
    /// Use this initializer when you want to depend on ``LayeredCache`` in your
    /// application architecture but do not yet have a persistent cache.
    ///
    /// - Parameter memoryCache: The in-memory cache to use as the first layer.
    public init<Memory: Cache>(
        memoryCache: Memory
    ) where Memory.Value == T {
        self.memoryCache = AnyCache(memoryCache)
        self.persistentCache = nil
        self.setMemoryValueWithTimestamp = nil
    }

    /// Creates a layered cache that preserves timestamps when promoting values from persistence.
    ///
    /// Reads check `memoryCache` first. When a value exists only in `persistentCache`,
    /// the value is returned and also written into `memoryCache`; if the persistent
    /// layer reports a timestamp, that timestamp is preserved during promotion.
    ///
    /// Example:
    /// ```swift
    /// let memory = InMemoryCache<User>()
    /// let layered = LayeredCache(memoryCache: memory, persistentCache: diskCache)
    /// ```
    ///
    /// - Parameters:
    ///   - memoryCache: A timestamp-capable memory cache.
    ///   - persistentCache: A persistent cache (disk, database, etc.) provided by the client.
    public init<Memory: TimestampedCache, Persistent: Cache>(
        memoryCache: Memory,
        persistentCache: Persistent
    ) where Memory.Value == T, Persistent.Value == T {
        self.memoryCache = AnyCache(memoryCache)
        self.persistentCache = AnyCache(persistentCache)
        self.setMemoryValueWithTimestamp = { value, key, timestamp in
            await memoryCache.setValue(value, forKey: key, timestamp: timestamp)
        }
    }

    // MARK: - Cache API

    /// Retrieves a value from memory first, then persistence if available.
    ///
    /// - Parameter key: The cache key to look up.
    /// - Returns: The cached value if it exists in either layer; otherwise `nil`.
    public func value(forKey key: CacheKey) async -> T? {
        if let inMemory = await memoryCache.value(forKey: key) {
            Logger.debug("Cache hit in memory")
            return inMemory
        }

        guard let persistentCache else {
            Logger.debug("Cache miss")
            return nil
        }

        guard let persisted = await persistentCache.value(forKey: key) else {
            Logger.debug("Cache miss in both layers")
            return nil
        }

        Logger.debug("Cache hit in persistent layer, promoting to memory")
        if let timestamp = await persistentCache.timestamp(forKey: key),
            let setWithTimestamp = setMemoryValueWithTimestamp
        {
            await setWithTimestamp(persisted, key, timestamp)
        } else {
            await memoryCache.setValue(persisted, forKey: key)
        }

        return persisted
    }

    /// Stores a value in every configured cache layer.
    ///
    /// - Parameters:
    ///   - value: The value to cache.
    ///   - key: The cache key to associate with the value.
    public func setValue(_ value: T, forKey key: CacheKey) async {
        await memoryCache.setValue(value, forKey: key)
        await persistentCache?.setValue(value, forKey: key)
    }

    /// Removes a value from every configured cache layer.
    ///
    /// - Parameter key: The cache key to remove.
    public func removeValue(forKey key: CacheKey) async {
        await memoryCache.removeValue(forKey: key)
        await persistentCache?.removeValue(forKey: key)
    }

    /// Removes all values from every configured cache layer.
    public func removeAll() async {
        await memoryCache.removeAll()
        await persistentCache?.removeAll()
    }

    /// Returns the timestamp from memory first, then persistence if available.
    ///
    /// - Parameter key: The cache key to inspect.
    /// - Returns: The timestamp for the first matching layer, or `nil` if absent.
    public func timestamp(forKey key: CacheKey) async -> Date? {
        // Check memory first to match value() priority order
        if let memoryTimestamp = await memoryCache.timestamp(forKey: key) {
            return memoryTimestamp
        }

        // Fall back to persistent cache
        if let persistentCache {
            return await persistentCache.timestamp(forKey: key)
        }

        return nil
    }
}
