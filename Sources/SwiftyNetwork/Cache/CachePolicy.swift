import Foundation

// MARK: - Cache Policy

/// Defines different caching strategies for repository fetches.
///
/// Pass a policy to ``GenericRepository/fetch(using:cacheKey:policy:)`` to choose
/// whether a request should prefer cached data, force a remote reload, or bound
/// cache staleness by age.
///
/// Example:
/// ```swift
/// let user = try await repository.fetch(
///     using: UserEndpoint(id: "123"),
///     cacheKey: .user("123", resource: "profile"),
///     policy: .returnCacheIfNotExpired(maxAge: 300)
/// )
/// ```
public enum CachePolicy: Sendable {
    /// Return cached data if available; otherwise fetch from remote and cache it.
    case returnCacheElseLoad

    /// Always fetch from remote, ignoring any cached data, and update the cache.
    case reloadIgnoringCache

    /// Return cached data if not expired; otherwise fetch from remote and update cache.
    ///
    /// - Parameter maxAge: Maximum age in seconds for cached data to be considered valid.
    case returnCacheIfNotExpired(maxAge: TimeInterval)

    /// Default caching policy.
    ///
    /// Equivalent to ``CachePolicy/returnCacheElseLoad``.
    public static let `default`: CachePolicy = .returnCacheElseLoad

    /// Determines if cached data should be used based on its age.
    ///
    /// This helper is mainly useful for custom repository implementations. For
    /// ``CachePolicy/returnCacheElseLoad`` it returns `true`, for
    /// ``CachePolicy/reloadIgnoringCache`` it returns `false`, and for
    /// ``CachePolicy/returnCacheIfNotExpired(maxAge:)`` it compares the supplied
    /// age to `maxAge`.
    ///
    /// Example:
    /// ```swift
    /// let policy = CachePolicy.returnCacheIfNotExpired(maxAge: 60)
    /// if policy.shouldUseCachedData(cacheAge: 30) {
    ///     return cachedValue
    /// }
    /// ```
    ///
    /// - Parameter cacheAge: The age of the cached data in seconds.
    /// - Returns: `true` if cached data should be used; `false` otherwise.
    public func shouldUseCachedData(cacheAge: TimeInterval) -> Bool {
        switch self {
        case .returnCacheElseLoad:
            return true
        case .reloadIgnoringCache:
            return false
        case .returnCacheIfNotExpired(let maxAge):
            return cacheAge <= maxAge
        }
    }
}
