import Foundation

// MARK: - Layered Cache

/// A cache that composes an in-memory layer with an optional persistent layer.
///
/// Reads consult the in-memory layer first, then fall back to the persistent layer.
/// Entries loaded from the persistent layer are promoted into memory with their
/// original timestamp.
/// Operations through this wrapper are serialized across suspension points,
/// so promotion cannot overwrite a later write or removal. ``removeAll()`` runs alone.
/// Access the underlying
/// tiers exclusively through this wrapper to preserve this guarantee. Custom
/// tiers must not call back into the same layered cache during an operation.
///
/// Example:
/// ```swift
/// let cache = LayeredCache(memoryCache: InMemoryCache<User>(maxSize: 100), persistentCache: diskCache)
/// await cache.setValue(user, forKey: "user:123:profile")
/// ```
public actor LayeredCache<T: Sendable>: Cache {
    let operations = CacheOperationGate<CacheKey>()
    private let memoryCache: any Cache<T>
    private let persistentCache: (any Cache<T>)?

    /// Creates a layered cache.
    ///
    /// Reads check `memoryCache` first. When an entry exists only in `persistentCache`,
    /// it is returned and also written into `memoryCache` with its original timestamp.
    ///
    /// Example:
    /// ```swift
    /// let layered = LayeredCache(memoryCache: InMemoryCache<User>(), persistentCache: diskCache)
    /// ```
    ///
    /// - Parameters:
    ///   - memoryCache: The in-memory cache to use as the first layer.
    ///   - persistentCache: A persistent cache (disk, database, etc.) provided by the client,
    ///     or `nil` to use only `memoryCache`. Defaults to `nil`.
    public init(memoryCache: some Cache<T>, persistentCache: (any Cache<T>)? = nil) {
        self.memoryCache = memoryCache
        self.persistentCache = persistentCache
    }

    // MARK: - Cache API

    /// Retrieves an entry from memory first, then persistence if available.
    ///
    /// - Parameter key: The cache key to look up.
    /// - Returns: The cached entry if it exists in either layer; otherwise `nil`.
    public func entry(forKey key: CacheKey) async -> CacheEntry<T>? {
        await operations.runExclusive { await self.storageEntry(forKey: key) }
    }

    private func storageEntry(forKey key: CacheKey) async -> CacheEntry<T>? {
        if let inMemory = await memoryCache.entry(forKey: key) {
            Logger.debug("Cache hit in memory", category: .cache)
            return inMemory
        }

        guard let persistentCache else {
            Logger.debug("Cache miss", category: .cache)
            return nil
        }

        guard let persisted = await persistentCache.entry(forKey: key) else {
            Logger.debug("Cache miss in both layers", category: .cache)
            return nil
        }

        Logger.debug("Cache hit in persistent layer, promoting to memory", category: .cache)
        await memoryCache.setEntry(persisted, forKey: key)
        return persisted
    }

    /// Stores an entry in every configured cache layer.
    ///
    /// - Parameters:
    ///   - entry: The value and timestamp to store.
    ///   - key: The cache key to associate with the entry.
    public func setEntry(_ entry: CacheEntry<T>, forKey key: CacheKey) async {
        await operations.runExclusive { await self.storageSetEntry(entry, forKey: key) }
    }

    private func storageSetEntry(_ entry: CacheEntry<T>, forKey key: CacheKey) async {
        await memoryCache.setEntry(entry, forKey: key)
        await persistentCache?.setEntry(entry, forKey: key)
    }

    /// Removes a value from every configured cache layer.
    ///
    /// - Parameter key: The cache key to remove.
    public func removeValue(forKey key: CacheKey) async {
        await operations.runExclusive { await self.storageRemoveValue(forKey: key) }
    }

    private func storageRemoveValue(forKey key: CacheKey) async {
        await memoryCache.removeValue(forKey: key)
        await persistentCache?.removeValue(forKey: key)
    }

    /// Removes all values from every configured cache layer.
    public func removeAll() async {
        await operations.runExclusive { await self.storageRemoveAll() }
    }

    private func storageRemoveAll() async {
        await memoryCache.removeAll()
        await persistentCache?.removeAll()
    }
}
