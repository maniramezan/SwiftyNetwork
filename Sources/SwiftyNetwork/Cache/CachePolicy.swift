import Foundation

// MARK: - Cache Policy

/// Defines different caching strategies for repository fetches.
///
/// Pass a policy to ``Repository/fetch(using:cacheKey:policy:)`` to choose
/// whether a request should prefer cached data, force a remote reload, bound
/// cache staleness by age, fall back to cached data when the network fails, or
/// show cached data at once while refreshing it in the background.
///
/// Example:
/// ```swift
/// let user = try await repository.fetch(
///     using: UserEndpoint(id: "123"),
///     cacheKey: "user:123:profile",
///     policy: .returnCacheIfNotExpired(maxAge: .seconds(300))
/// )
/// ```
public enum CachePolicy: Sendable, Equatable {
    /// Return cached data if available; otherwise fetch from remote and cache it.
    case returnCacheElseLoad

    /// Always fetch from remote, ignoring any cached data, and update the cache.
    case reloadIgnoringCache

    /// Return cached data if not expired; otherwise fetch from remote and update cache.
    ///
    /// - Parameter maxAge: Maximum age for cached data to be considered valid.
    case returnCacheIfNotExpired(maxAge: Duration)

    /// Fetch from remote and update the cache; if the fetch fails, return cached data when
    /// there is any, whatever its age.
    ///
    /// Use it for content that should be current but must stay available offline. The error
    /// is thrown only when nothing is cached. Check ``RepositoryResult/source`` to tell the
    /// user they are looking at saved data.
    case reloadElseReturnCache

    /// Return cached data at once, whatever its age, and when it is older than `maxAge` also
    /// refresh the cache from remote in the background. With nothing cached, fetch from remote.
    ///
    /// Also known as stale-while-revalidate. The refreshed value is returned by the next fetch;
    /// a failed background refresh is ignored and the cached data stays.
    ///
    /// - Parameter maxAge: The age after which cached data is refreshed in the background.
    case returnCacheAndRevalidate(maxAge: Duration)

    /// Default caching policy.
    ///
    /// Equivalent to ``CachePolicy/returnCacheElseLoad``.
    public static let `default`: CachePolicy = .returnCacheElseLoad

    /// Determines if cached data should be used based on its age.
    ///
    /// This helper is mainly useful for custom repository implementations. It answers
    /// whether cached data of that age is returned without waiting for the network:
    ///
    /// - ``CachePolicy/returnCacheElseLoad`` and
    ///   ``CachePolicy/returnCacheAndRevalidate(maxAge:)``: `true`. For the latter, use
    ///   ``shouldRevalidateCachedData(cacheAge:)`` to decide on a background refresh.
    /// - ``CachePolicy/reloadIgnoringCache`` and ``CachePolicy/reloadElseReturnCache``: `false`.
    ///   The latter uses cached data only after the network fails.
    /// - ``CachePolicy/returnCacheIfNotExpired(maxAge:)``: whether the age is within `maxAge`.
    ///
    /// Example:
    /// ```swift
    /// let policy = CachePolicy.returnCacheIfNotExpired(maxAge: .seconds(60))
    /// if policy.shouldUseCachedData(cacheAge: .seconds(30)) {
    ///     return cachedValue
    /// }
    /// ```
    ///
    /// - Parameter cacheAge: The age of the cached data.
    /// - Returns: `true` if cached data should be used; `false` otherwise.
    public func shouldUseCachedData(cacheAge: Duration) -> Bool {
        switch self {
        case .returnCacheElseLoad, .returnCacheAndRevalidate:
            return true
        case .reloadIgnoringCache, .reloadElseReturnCache:
            return false
        case .returnCacheIfNotExpired(let maxAge):
            return cacheAge <= maxAge
        }
    }

    /// Determines if returned cached data should also be refreshed in the background.
    ///
    /// - Parameter cacheAge: The age of the cached data.
    /// - Returns: `true` only for ``CachePolicy/returnCacheAndRevalidate(maxAge:)`` with data
    ///   older than its `maxAge`.
    public func shouldRevalidateCachedData(cacheAge: Duration) -> Bool {
        guard case .returnCacheAndRevalidate(let maxAge) = self else { return false }
        return cacheAge > maxAge
    }
}
