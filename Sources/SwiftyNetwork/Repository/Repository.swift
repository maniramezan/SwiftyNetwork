import Foundation

// MARK: - Local Data Source Protocol

/// Provides an abstraction for local data storage operations.
///
/// Repositories use this protocol to read, write, and timestamp cached entities
/// without depending on a specific cache implementation. Use
/// ``CacheBasedLocalDataSource`` to adapt any ``Cache``.
///
/// Example:
/// ```swift
/// let cache = InMemoryCache<User>()
/// let localDataSource = CacheBasedLocalDataSource(cache: cache)
/// let cached = await localDataSource.read(for: .user("123", resource: "profile"))
/// ```
public protocol LocalDataSource: Sendable {
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
/// This bridges the repository pattern with the caching system, allowing any
/// ``Cache`` implementation to be used as a local data source.
///
/// Example:
/// ```swift
/// let cache = InMemoryCache<User>()
/// let localDataSource = CacheBasedLocalDataSource(cache: cache)
/// await localDataSource.write(user, for: .user(user.id, resource: "profile"))
/// ```
public struct CacheBasedLocalDataSource<E: Sendable>: LocalDataSource {
    /// The entity type managed by this data source.
    public typealias Entity = E

    private let _read: @Sendable (CacheKey) async -> E?
    private let _write: @Sendable (E, CacheKey) async -> Void
    private let _remove: @Sendable (CacheKey) async -> Void
    private let _removeAll: @Sendable () async -> Void
    private let _timestamp: @Sendable (CacheKey) async -> Date?

    /// Creates a cache-based local data source from any ``Cache`` implementation.
    ///
    /// - Parameter cache: The cache implementation to use for storage.
    public init<C: Cache>(cache: C) where C.Value == E {
        _read = { key in await cache.value(forKey: key) }
        _write = { value, key in await cache.setValue(value, forKey: key) }
        _remove = { key in await cache.removeValue(forKey: key) }
        _removeAll = { await cache.removeAll() }
        _timestamp = { key in await cache.timestamp(forKey: key) }
    }

    /// Reads an entity from the wrapped cache.
    ///
    /// - Parameter key: The cache key to look up.
    /// - Returns: The cached entity if present, otherwise `nil`.
    public func read(for key: CacheKey) async -> E? {
        await _read(key)
    }

    /// Writes an entity to the wrapped cache.
    ///
    /// - Parameters:
    ///   - entity: The entity to store.
    ///   - key: The cache key to associate with the entity.
    public func write(_ entity: E, for key: CacheKey) async {
        await _write(entity, key)
    }

    /// Removes an entity from the wrapped cache.
    ///
    /// - Parameter key: The cache key to remove.
    public func remove(for key: CacheKey) async {
        await _remove(key)
    }

    /// Removes all entities from the wrapped cache.
    public func removeAll() async {
        await _removeAll()
    }

    /// Returns the wrapped cache timestamp for an entity.
    ///
    /// - Parameter key: The cache key to inspect.
    /// - Returns: The cached timestamp, or `nil` if no entity exists for `key`.
    public func timestamp(for key: CacheKey) async -> Date? {
        await _timestamp(key)
    }
}

// MARK: - Repository Protocol

/// A repository provides a unified interface for fetching data from remote and local sources.
///
/// The repository pattern abstracts the data access logic and handles caching strategies,
/// providing a clean separation between data sources and business logic.
///
/// Example:
/// ```swift
/// let repository = GenericRepository<User>(
///     networkDataSource: NetworkClient(),
///     localDataSource: CacheBasedLocalDataSource(cache: InMemoryCache<User>())
/// )
/// let user = try await repository.fetch(
///     using: UserEndpoint(id: "123"),
///     cacheKey: .user("123", resource: "profile"),
///     policy: .default
/// )
/// ```
public protocol Repository: Sendable {
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
///
/// Example:
/// ```swift
/// let cache = InMemoryCache<User>(maxSize: 100)
/// let localDataSource = CacheBasedLocalDataSource(cache: cache)
/// let repository = GenericRepository<User>(
///     networkDataSource: NetworkClient(),
///     localDataSource: localDataSource
/// )
/// ```
public struct GenericRepository<Entity: Decodable & Sendable>: Repository {

    private let networkDataSource: any NetworkDataSource
    private let localRead: @Sendable (CacheKey) async -> Entity?
    private let localWrite: @Sendable (Entity, CacheKey) async -> Void
    private let localTimestamp: @Sendable (CacheKey) async -> Date?

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

    /// Fetches an entity using the specified endpoint and caching strategy.
    ///
    /// The repository writes successful network responses to the local data source.
    /// It does not return stale cached data when the network request fails under
    /// ``CachePolicy/reloadIgnoringCache`` or expired
    /// ``CachePolicy/returnCacheIfNotExpired(maxAge:)`` policies.
    ///
    /// Example:
    /// ```swift
    /// let user = try await repository.fetch(
    ///     using: UserEndpoint(id: "123"),
    ///     cacheKey: .user("123", resource: "profile"),
    ///     policy: .returnCacheElseLoad
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - endpoint: The network endpoint to fetch from.
    ///   - cacheKey: The key to use for caching the entity.
    ///   - policy: The cache policy determining fetch behavior.
    /// - Returns: The fetched entity.
    /// - Throws: `NetworkError` if the fetch fails.
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
