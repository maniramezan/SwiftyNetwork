import Foundation

// MARK: - Layered Cache

/// A cache that composes an in-memory layer with an optional persistent layer.
///
/// Reads consult the in-memory layer first, then fall back to the persistent layer.
/// Values loaded from the persistent layer are promoted into memory.
public actor LayeredCache<T: Sendable>: Cache {
    private let memoryCache: AnyCache<T>
    private let persistentCache: AnyCache<T>?
    private let setMemoryValueWithTimestamp: (@Sendable (T, CacheKey, Date) async -> Void)?

    /// Creates a layered cache with only a memory cache.
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

    public func value(forKey key: CacheKey) async -> T? {
        if let inMemory = await memoryCache.value(forKey: key) {
            Logger.debug("Cache hit in memory for key: \(key.rawValue)")
            return inMemory
        }

        guard let persistentCache else {
            Logger.debug("Cache miss for key: \(key.rawValue)")
            return nil
        }

        guard let persisted = await persistentCache.value(forKey: key) else {
            Logger.debug("Cache miss in both layers for key: \(key.rawValue)")
            return nil
        }

        Logger.debug("Cache hit in persistent layer, promoting to memory for key: \(key.rawValue)")
        if let timestamp = await persistentCache.timestamp(forKey: key),
            let setWithTimestamp = setMemoryValueWithTimestamp
        {
            await setWithTimestamp(persisted, key, timestamp)
        } else {
            await memoryCache.setValue(persisted, forKey: key)
        }

        return persisted
    }

    public func setValue(_ value: T, forKey key: CacheKey) async {
        await memoryCache.setValue(value, forKey: key)
        await persistentCache?.setValue(value, forKey: key)
    }

    public func removeValue(forKey key: CacheKey) async {
        await memoryCache.removeValue(forKey: key)
        await persistentCache?.removeValue(forKey: key)
    }

    public func removeAll() async {
        await memoryCache.removeAll()
        await persistentCache?.removeAll()
    }

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
