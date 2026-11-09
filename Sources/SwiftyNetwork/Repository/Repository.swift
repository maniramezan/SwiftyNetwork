import Foundation

// MARK: - Repository Protocol

/// A repository provides a unified interface for fetching data from remote and local sources.
///
/// The repository pattern abstracts the data access logic and handles caching strategies,
/// providing a clean separation between data sources and business logic.
///
/// Example:
/// ```swift
/// let repository = GenericRepository(client: NetworkClient(), cache: InMemoryCache<User>())
/// let user = try await repository.fetch(
///     using: UserEndpoint(id: "123"),
///     cacheKey: "user:123:profile",
///     policy: .default
/// )
/// ```
public protocol Repository<Entity>: Sendable {
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

/// A generic repository implementation that combines a network client and a cache.
///
/// This repository handles different caching strategies and provides automatic
/// fallback between remote and cached data based on the specified policy.
///
/// Example:
/// ```swift
/// let repository = GenericRepository(
///     client: NetworkClient(),
///     cache: InMemoryCache<User>(maxSize: 100)
/// )
/// ```
public struct GenericRepository<Entity: Decodable & Sendable>: Repository {

    private let client: any APIClient
    private let cache: any Cache<Entity>

    /// Creates a generic repository.
    ///
    /// - Parameters:
    ///   - client: The client that performs network requests.
    ///   - cache: Where fetched entities are stored. Any ``Cache``, such as
    ///     ``InMemoryCache``, ``LayeredCache``, or your own disk cache.
    public init(client: some APIClient, cache: some Cache<Entity>) {
        self.client = client
        self.cache = cache
    }

    /// Fetches an entity using the specified endpoint and caching strategy.
    ///
    /// The repository writes successful network responses to the cache.
    /// It does not return stale cached data when the network request fails under
    /// ``CachePolicy/reloadIgnoringCache`` or expired
    /// ``CachePolicy/returnCacheIfNotExpired(maxAge:)`` policies.
    ///
    /// Example:
    /// ```swift
    /// let user = try await repository.fetch(
    ///     using: UserEndpoint(id: "123"),
    ///     cacheKey: "user:123:profile",
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
        if let cached = await cache.value(forKey: cacheKey) {
            return cached
        }

        return try await fetchFromNetworkAndCache(endpoint: endpoint, cacheKey: cacheKey)
    }

    private func fetchFromNetworkAndCache(
        endpoint: any NetworkEndpoint,
        cacheKey: CacheKey
    ) async throws -> Entity {
        let freshEntity = try await client.request(endpoint, responseType: Entity.self)
        await cache.setValue(freshEntity, forKey: cacheKey)
        return freshEntity
    }

    private func fetchWithExpirationCheck(
        endpoint: any NetworkEndpoint,
        cacheKey: CacheKey,
        maxAge: Duration
    ) async throws -> Entity {
        // One entry read, so the value and its timestamp come from the same write.
        if let entry = await cache.entry(forKey: cacheKey),
            CachePolicy.returnCacheIfNotExpired(maxAge: maxAge).shouldUseCachedData(cacheAge: entry.age())
        {
            return entry.value
        }

        return try await fetchFromNetworkAndCache(endpoint: endpoint, cacheKey: cacheKey)
    }
}
