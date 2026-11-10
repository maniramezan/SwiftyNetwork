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
/// let user = try await repository.fetch(using: UserEndpoint(id: "123"), cacheKey: "user:123:profile")
/// ```
public protocol Repository<Entity>: Sendable {
    /// The type of entity managed by this repository.
    associatedtype Entity: Sendable

    /// Fetches an entity using the specified endpoint and caching strategy, reporting where
    /// it came from.
    ///
    /// - Parameters:
    ///   - endpoint: The network endpoint to fetch data from.
    ///   - cacheKey: The key to use for caching the entity.
    ///   - policy: The caching policy to apply.
    /// - Returns: The requested entity, its source, and when it was fetched.
    /// - Throws: An error if the fetch operation fails.
    func fetchResult(
        using endpoint: any NetworkEndpoint,
        cacheKey: CacheKey,
        policy: CachePolicy
    ) async throws -> RepositoryResult<Entity>
}

extension Repository {
    /// Fetches an entity using the specified endpoint and caching strategy.
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
    ///   - endpoint: The network endpoint to fetch data from.
    ///   - cacheKey: The key to use for caching the entity.
    ///   - policy: The caching policy to apply. Defaults to ``CachePolicy/default``.
    /// - Returns: The requested entity.
    /// - Throws: An error if the fetch operation fails.
    public func fetch(
        using endpoint: any NetworkEndpoint,
        cacheKey: CacheKey,
        policy: CachePolicy = .default
    ) async throws -> Entity {
        try await fetchResult(using: endpoint, cacheKey: cacheKey, policy: policy).value
    }
}

// MARK: - Generic Repository Implementation

/// A generic repository implementation that combines a network client and a cache.
///
/// This repository handles the caching strategies of ``CachePolicy`` and writes every
/// successful network response to the cache.
///
/// Concurrent fetches that reach the network for the same cache key share one request, so a
/// screen and a widget asking for the same resource at once cost one round trip. Use one cache
/// key per resource, and include whatever scopes it, such as the user's identifier. Requests
/// are shared across copies of a repository value, not across separately created repositories.
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
    private let inFlight = FetchCoalescer<RepositoryResult<Entity>>()

    /// Creates a generic repository.
    ///
    /// - Parameters:
    ///   - client: The client that performs network requests.
    ///   - cache: Where fetched entities are stored. Any ``Cache``, such as
    ///     ``InMemoryCache``, ``DiskCache``, or a ``LayeredCache`` of both.
    public init(client: some APIClient, cache: some Cache<Entity>) {
        self.client = client
        self.cache = cache
    }

    /// Fetches an entity using the specified endpoint and caching strategy, reporting where
    /// it came from.
    ///
    /// The repository writes successful network responses to the cache. It returns cached
    /// data after a failed request only under ``CachePolicy/reloadElseReturnCache``; under
    /// ``CachePolicy/reloadIgnoringCache`` and an expired
    /// ``CachePolicy/returnCacheIfNotExpired(maxAge:)`` the error is thrown.
    ///
    /// Example:
    /// ```swift
    /// let result = try await repository.fetchResult(
    ///     using: UserEndpoint(id: "123"),
    ///     cacheKey: "user:123:profile",
    ///     policy: .returnCacheAndRevalidate(maxAge: .seconds(60))
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - endpoint: The network endpoint to fetch from.
    ///   - cacheKey: The key to use for caching the entity.
    ///   - policy: The cache policy determining fetch behavior.
    /// - Returns: The fetched entity, its source, and when it was fetched.
    /// - Throws: `NetworkError` if the fetch fails, or `CancellationError` if the calling task
    ///   was cancelled.
    public func fetchResult(
        using endpoint: any NetworkEndpoint,
        cacheKey: CacheKey,
        policy: CachePolicy
    ) async throws -> RepositoryResult<Entity> {
        switch policy {
        case .returnCacheElseLoad:
            if let cached = await cachedResult(forKey: cacheKey) {
                return cached
            }
            return try await load(endpoint, cacheKey: cacheKey)

        case .reloadIgnoringCache:
            return try await load(endpoint, cacheKey: cacheKey)

        case .returnCacheIfNotExpired(let maxAge):
            // One entry read, so the value and its timestamp come from the same write.
            if let cached = await cachedResult(forKey: cacheKey), cached.age() <= maxAge {
                return cached
            }
            return try await load(endpoint, cacheKey: cacheKey)

        case .reloadElseReturnCache:
            do {
                return try await load(endpoint, cacheKey: cacheKey)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard let cached = await cachedResult(forKey: cacheKey) else { throw error }
                Logger.info("Network fetch failed; returning cached data", category: .repository)
                return cached
            }

        case .returnCacheAndRevalidate(let maxAge):
            guard let cached = await cachedResult(forKey: cacheKey) else {
                return try await load(endpoint, cacheKey: cacheKey)
            }
            if cached.age() > maxAge {
                revalidate(endpoint, cacheKey: cacheKey)
            }
            return cached
        }
    }

    /// Removes the cached entity for `cacheKey`, so the next fetch loads it from the network.
    ///
    /// Call it after a mutation that changes the resource.
    ///
    /// - Parameter cacheKey: The key of the entity to remove.
    public func removeCachedValue(forKey cacheKey: CacheKey) async {
        await cache.removeValue(forKey: cacheKey)
    }

    /// Removes every cached entity, for example on sign-out.
    public func removeAllCachedValues() async {
        await cache.removeAll()
    }

    // MARK: - Private Fetch Methods

    private func cachedResult(forKey cacheKey: CacheKey) async -> RepositoryResult<Entity>? {
        guard let entry = await cache.entry(forKey: cacheKey) else { return nil }
        return RepositoryResult(value: entry.value, source: .cache, timestamp: entry.timestamp)
    }

    /// Fetches from the network and caches the result, sharing the request with concurrent
    /// callers for the same key.
    private func load(_ endpoint: any NetworkEndpoint, cacheKey: CacheKey) async throws -> RepositoryResult<Entity> {
        let result = try await inFlight.run(for: cacheKey) { [client, cache] in
            let entity = try await client.request(endpoint, responseType: Entity.self)
            let entry = CacheEntry(entity)
            await cache.setEntry(entry, forKey: cacheKey)
            return RepositoryResult(value: entity, source: .network, timestamp: entry.timestamp)
        }
        // The shared request is not cancelled with one caller, so report cancellation here.
        try Task.checkCancellation()
        return result
    }

    /// Refreshes the cache in the background. The caller already has cached data, so a failure
    /// is only logged.
    private func revalidate(_ endpoint: any NetworkEndpoint, cacheKey: CacheKey) {
        Task {
            do {
                _ = try await load(endpoint, cacheKey: cacheKey)
            } catch {
                Logger.info("Background revalidation failed; keeping cached data", category: .repository)
            }
        }
    }
}
