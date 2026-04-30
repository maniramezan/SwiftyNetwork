import Foundation

// MARK: - Cache Protocol

/// A generic caching interface that provides thread-safe storage with timestamp tracking.
///
/// Implement this protocol for custom memory, disk, database, or hybrid caches.
/// Conforming types must be `Sendable` because repositories and network clients
/// can call cache operations across concurrency domains.
///
/// Example:
/// ```swift
/// let cache = InMemoryCache<User>()
/// let key = CacheKey.user("123", resource: "profile")
/// await cache.setValue(user, forKey: key)
/// let cachedUser = await cache.value(forKey: key)
/// ```
public protocol Cache: Sendable {
    /// The type of values stored in this cache.
    associatedtype Value: Sendable

    /// Retrieves a value from the cache for the given key.
    ///
    /// - Parameter key: The cache key to look up.
    /// - Returns: The cached value if it exists, otherwise `nil`.
    func value(forKey key: CacheKey) async -> Value?

    /// Stores a value in the cache for the given key.
    ///
    /// - Parameters:
    ///   - value: The value to cache.
    ///   - key: The cache key to associate with the value.
    func setValue(_ value: Value, forKey key: CacheKey) async

    /// Removes a value from the cache for the given key.
    ///
    /// - Parameter key: The cache key to remove.
    func removeValue(forKey key: CacheKey) async

    /// Removes all values from the cache.
    func removeAll() async

    /// Returns the timestamp when the value was last stored for the given key.
    ///
    /// - Parameter key: The cache key to look up.
    /// - Returns: The timestamp when the value was stored, or `nil` if no value exists.
    func timestamp(forKey key: CacheKey) async -> Date?
}

/// A cache that can store values with a caller-supplied timestamp.
///
/// Use this to preserve timestamps when promoting values between cache layers.
/// ``InMemoryCache`` conforms to this protocol, which lets ``LayeredCache`` keep
/// original persistence timestamps when promoting values into memory.
///
/// Example:
/// ```swift
/// let cache = InMemoryCache<User>()
/// await cache.setValue(user, forKey: key, timestamp: Date().addingTimeInterval(-60))
/// ```
public protocol TimestampedCache: Cache {
    /// Stores a value in the cache with an explicit timestamp.
    ///
    /// - Parameters:
    ///   - value: The value to cache.
    ///   - key: The cache key to associate with the value.
    ///   - timestamp: The timestamp to record for the cached value.
    func setValue(_ value: Value, forKey key: CacheKey, timestamp: Date) async
}

/// A marker protocol for caches that persist values to durable storage (e.g., disk).
///
/// Implement this in client apps to plug their own on-disk cache into SwiftyNetwork.
/// The protocol does not add requirements beyond ``Cache``; it documents that the
/// values survive beyond the current process or memory cache lifetime.
///
/// Example:
/// ```swift
/// actor DiskUserCache: PersistentCache {
///     typealias Value = User
///
///     func value(forKey key: CacheKey) async -> User? { nil }
///     func setValue(_ value: User, forKey key: CacheKey) async {}
///     func removeValue(forKey key: CacheKey) async {}
///     func removeAll() async {}
///     func timestamp(forKey key: CacheKey) async -> Date? { nil }
/// }
/// ```
public protocol PersistentCache: Cache {}
