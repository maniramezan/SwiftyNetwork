import Foundation

// MARK: - Local Data Source Protocol

/// Provides an abstraction for local data storage operations.
public protocol LocalDataSource {
    /// The type of entity stored by this data source.
    associatedtype Entity: Sendable

    /// Retrieves an entity from local storage.
    ///
    /// - Parameter key: The cache key for the entity.
    /// - Returns: The entity if it exists, otherwise `nil`.
    func read(for key: CacheKey) async -> Entity?

    /// Stores an entity in local storage.
    ///
    /// - Parameters:
    ///   - entity: The entity to store.
    ///   - key: The cache key to associate with the entity.
    func write(_ entity: Entity, for key: CacheKey) async

    /// Removes an entity from local storage.
    ///
    /// - Parameter key: The cache key for the entity to remove.
    func remove(for key: CacheKey) async

    /// Removes all entities from local storage.
    func removeAll() async

    /// Returns the timestamp when the entity was last stored.
    ///
    /// - Parameter key: The cache key for the entity.
    /// - Returns: The storage timestamp, or `nil` if the entity doesn't exist.
    func timestamp(for key: CacheKey) async -> Date?
}

/// A local data source implementation backed by a generic cache.
///
/// This provides a bridge between the repository pattern and the caching system,
/// allowing any cache implementation to be used as a local data source.
public struct CacheBasedLocalDataSource<E: Sendable>: LocalDataSource {
    public typealias Entity = E

    private let cache: AnyCache<E>

    /// Creates a cache-based local data source.
    ///
    /// - Parameter cache: The cache implementation to use for storage.
    public init(cache: AnyCache<E>) {
        self.cache = cache
    }

    /// Retrieves an entity from the local cache for the provided key.
    ///
    /// - Parameter key: The cache key for the entity.
    /// - Returns: The entity if present; otherwise `nil`.
    public func read(for key: CacheKey) async -> E? {
        await cache.value(forKey: key)
    }

    /// Stores an entity in local cache for the provided key.
    ///
    /// - Parameters:
    ///   - entity: The entity to store.
    ///   - key: The cache key to associate with the entity.
    public func write(_ entity: E, for key: CacheKey) async {
        await cache.setValue(entity, forKey: key)
    }

    /// Removes the entity associated with the given key from local cache.
    ///
    /// - Parameter key: The cache key to remove.
    public func remove(for key: CacheKey) async {
        await cache.removeValue(forKey: key)
    }

    /// Removes all entities from the local cache.
    public func removeAll() async {
        await cache.removeAll()
    }

    /// Returns the timestamp when the entity was last stored in the local cache.
    ///
    /// - Parameter key: The cache key for the entity.
    /// - Returns: The timestamp when the entity was stored, or `nil` if not present.
    public func timestamp(for key: CacheKey) async -> Date? {
        await cache.timestamp(forKey: key)
    }
}

// MARK: - Repository Protocol

/// A repository provides a unified interface for fetching data from remote and local sources.
///
/// The repository pattern abstracts the data access logic and handles caching strategies,
/// providing a clean separation between data sources and business logic.
public protocol Repository {
    /// The type of entity managed by this repository.
    associatedtype Entity: Sendable

    /// Fetches an entity using the specified endpoint and caching strategy.
    ///
    /// - Parameters:
    ///   - endpoint: The network endpoint to fetch data from.
    ///   - cacheKey: The key to use for caching the entity.
    ///   - policy: The caching policy to apply.
    /// - Returns: The requested entity.
    /// - Throws: An error if the fetch operation fails.
    func fetch(
        using endpoint: any NetworkEndpoint,
        cacheKey: CacheKey,
        policy: CachePolicy
    ) async throws -> Entity
}

// MARK: - Generic Repository Implementation

/// A generic repository implementation that combines network and local data sources.
///
/// This repository handles different caching strategies and provides automatic
/// fallback between remote and cached data based on the specified policy.
public struct GenericRepository<Entity: Decodable & Sendable>: Repository {

    private let networkDataSource: any NetworkDataSource
    private let localRead: (CacheKey) async -> Entity?
    private let localWrite: (Entity, CacheKey) async -> Void
    private let localTimestamp: (CacheKey) async -> Date?

    /// Creates a generic repository with the specified data sources.
    ///
    /// This initializer uses type erasure to avoid exposing opaque 'some' types in the public API,
    /// providing better flexibility for users of the repository.
    ///
    /// - Parameters:
    ///   - networkDataSource: The remote data source for network requests.
    ///   - localDataSource: The local data source for caching.
    public init<L: LocalDataSource>(
        networkDataSource: some NetworkDataSource,
        localDataSource: L
    ) where L.Entity == Entity {
        self.networkDataSource = networkDataSource
        self.localRead = { key in await localDataSource.read(for: key) }
        self.localWrite = { entity, key in await localDataSource.write(entity, for: key) }
        self.localTimestamp = { key in await localDataSource.timestamp(for: key) }
    }

    public func fetch(
        using endpoint: any NetworkEndpoint,
        cacheKey: CacheKey,
        policy: CachePolicy
    ) async throws -> Entity {
        switch policy {
        case .returnCacheElseLoad:
            return try await fetchWithCacheFallback(endpoint: endpoint, cacheKey: cacheKey)

        case .reloadIgnoringCache:
            return try await fetchFromNetworkAndCache(endpoint: endpoint, cacheKey: cacheKey)

        case .returnCacheIfNotExpired(let maxAge):
            return try await fetchWithExpirationCheck(
                endpoint: endpoint,
                cacheKey: cacheKey,
                maxAge: maxAge
            )
        }
    }

    // MARK: - Private Fetch Methods

    private func fetchWithCacheFallback(
        endpoint: any NetworkEndpoint,
        cacheKey: CacheKey
    ) async throws -> Entity {
        if let cachedEntity = await localRead(cacheKey) {
            return cachedEntity
        }

        return try await fetchFromNetworkAndCache(endpoint: endpoint, cacheKey: cacheKey)
    }

    private func fetchFromNetworkAndCache(
        endpoint: any NetworkEndpoint,
        cacheKey: CacheKey
    ) async throws -> Entity {
        let freshEntity = try await networkDataSource.request(endpoint, responseType: Entity.self)
        await localWrite(freshEntity, cacheKey)
        return freshEntity
    }

    private func fetchWithExpirationCheck(
        endpoint: any NetworkEndpoint,
        cacheKey: CacheKey,
        maxAge: TimeInterval
    ) async throws -> Entity {
        if let cachedEntity = await localRead(cacheKey),
            let timestamp = await localTimestamp(cacheKey)
        {

            let cacheAge = Date().timeIntervalSince(timestamp)
            let cachePolicy = CachePolicy.returnCacheIfNotExpired(maxAge: maxAge)
            if cachePolicy.shouldUseCachedData(cacheAge: cacheAge) {
                return cachedEntity
            }
        }

        return try await fetchFromNetworkAndCache(endpoint: endpoint, cacheKey: cacheKey)
    }
}
