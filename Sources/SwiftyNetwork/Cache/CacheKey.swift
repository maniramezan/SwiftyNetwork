import Foundation

// MARK: - Cache Key

/// A type-safe cache key for storing and retrieving cached values.
///
/// Cache keys provide a consistent way to identify cached data across the system.
/// They support string-based keys with additional convenience initializers for common patterns.
///
/// Example:
/// ```swift
/// let userKey = CacheKey.user("123", resource: "profile")
/// let endpointKey = CacheKey.endpoint("/users", parameters: ["page": "1"])
/// ```
public struct CacheKey: Hashable, Sendable {
    /// The underlying string value of the cache key.
    public let rawValue: String

    /// Creates a cache key with the specified raw value.
    ///
    /// Example:
    /// ```swift
    /// let key = CacheKey("user:123:profile")
    /// ```
    ///
    /// - Parameter rawValue: The string value for the cache key.
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a cache key from a URL, using its absolute string representation.
    ///
    /// Example:
    /// ```swift
    /// if let url = URL(string: "https://api.example.com/users/123") {
    ///     let key = CacheKey(url: url)
    /// }
    /// ```
    ///
    /// - Parameter url: The URL to create a cache key from.
    public init(url: URL) {
        self.rawValue = url.absoluteString
    }

    /// Creates a cache key by combining multiple components with a separator.
    ///
    /// Example:
    /// ```swift
    /// let key = CacheKey(components: ["users", "123", "posts"])
    /// ```
    ///
    /// - Parameters:
    ///   - components: The string components to combine.
    ///   - separator: The separator to use between components. Defaults to ":".
    public init(components: [String], separator: String = ":") {
        self.rawValue = components.joined(separator: separator)
    }
}

// MARK: - Convenience Extensions

extension CacheKey {
    /// Creates a cache key for user-specific data.
    ///
    /// Example:
    /// ```swift
    /// let key = CacheKey.user("123", resource: "settings")
    /// ```
    ///
    /// - Parameters:
    ///   - userId: The user identifier.
    ///   - resource: The resource identifier.
    /// - Returns: A cache key formatted as "user:{userId}:{resource}".
    public static func user(_ userId: String, resource: String) -> CacheKey {
        CacheKey(components: ["user", userId, resource])
    }

    /// Creates a cache key for API endpoint data.
    ///
    /// Parameters are sorted by key so equivalent dictionaries produce stable
    /// cache keys regardless of dictionary iteration order.
    ///
    /// Example:
    /// ```swift
    /// let key = CacheKey.endpoint("/posts", parameters: ["page": "1", "limit": "20"])
    /// ```
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint path.
    ///   - parameters: Additional parameters to include in the key.
    /// - Returns: A cache key for the API endpoint.
    public static func endpoint(_ endpoint: String, parameters: [String: String] = [:]) -> CacheKey {
        let sortedParams = parameters.sorted { $0.key < $1.key }
        let paramString = sortedParams.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let fullKey = paramString.isEmpty ? endpoint : "\(endpoint)?\(paramString)"
        return CacheKey(fullKey)
    }
}
