import Foundation

// MARK: - Cache Policy

/// Defines different caching strategies for network requests.
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
    public static let `default`: CachePolicy = .returnCacheElseLoad

    /// Determines if cached data should be used based on its age.
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
