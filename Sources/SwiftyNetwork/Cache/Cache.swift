import Foundation

// MARK: - Cache Entry

/// A cached value together with the time it was stored.
///
/// Caches hand out the value and its timestamp as one snapshot, so a reader
/// can never pair a value with the timestamp of a different write.
///
/// Example:
/// ```swift
/// if let entry = await cache.entry(forKey: key), entry.age() < .seconds(300) {
///     return entry.value
/// }
/// ```
public struct CacheEntry<Value: Sendable>: Sendable {
    /// The cached value.
    public var value: Value

    /// When the value was stored.
    public var timestamp: Date

    /// Creates a cache entry.
    ///
    /// - Parameters:
    ///   - value: The value to cache.
    ///   - timestamp: When the value was stored. Defaults to now.
    public init(_ value: Value, timestamp: Date = Date()) {
        self.value = value
        self.timestamp = timestamp
    }

    /// How long ago the value was stored.
    ///
    /// - Parameter now: The reference instant. Defaults to now.
    /// - Returns: The time between ``timestamp`` and `now`.
    public func age(at now: Date = Date()) -> Duration {
        .seconds(now.timeIntervalSince(timestamp))
    }
}

extension CacheEntry: Equatable where Value: Equatable {}

// MARK: - Cache Protocol

/// A generic caching interface that stores values with the time they were written.
///
/// Implement this protocol for custom memory, disk, database, or hybrid caches.
/// Conforming types must be `Sendable` because repositories and network clients
/// can call cache operations across concurrency domains.
///
/// The requirements work on whole ``CacheEntry`` values, so a conformer stores
/// and returns the timestamp it was given. ``value(forKey:)`` and
/// ``setValue(_:forKey:)`` are conveniences built on them.
///
/// Example:
/// ```swift
/// let cache = InMemoryCache<User>()
/// let key: CacheKey = "user:123:profile"
/// await cache.setValue(user, forKey: key)
/// let cachedUser = await cache.value(forKey: key)
/// ```
///
/// A custom persistent cache:
/// ```swift
/// actor DiskUserCache: Cache {
///     func entry(forKey key: CacheKey) async -> CacheEntry<User>? { nil }
///     func setEntry(_ entry: CacheEntry<User>, forKey key: CacheKey) async {}
///     func removeValue(forKey key: CacheKey) async {}
///     func removeAll() async {}
/// }
/// ```
public protocol Cache<Value>: Sendable {
    /// The type of values stored in this cache.
    associatedtype Value: Sendable

    /// Retrieves the entry stored for the given key.
    ///
    /// - Parameter key: The cache key to look up.
    /// - Returns: The value and its timestamp, or `nil` if nothing is stored for `key`.
    func entry(forKey key: CacheKey) async -> CacheEntry<Value>?

    /// Stores an entry for the given key, keeping its timestamp.
    ///
    /// - Parameters:
    ///   - entry: The value and timestamp to store.
    ///   - key: The cache key to associate with the entry.
    func setEntry(_ entry: CacheEntry<Value>, forKey key: CacheKey) async

    /// Removes the entry for the given key.
    ///
    /// - Parameter key: The cache key to remove.
    func removeValue(forKey key: CacheKey) async

    /// Removes all entries from the cache.
    func removeAll() async
}

extension Cache {
    /// Retrieves the value stored for the given key.
    ///
    /// - Parameter key: The cache key to look up.
    /// - Returns: The cached value if it exists, otherwise `nil`.
    public func value(forKey key: CacheKey) async -> Value? {
        await entry(forKey: key)?.value
    }

    /// Stores a value for the given key, timestamped now.
    ///
    /// - Parameters:
    ///   - value: The value to cache.
    ///   - key: The cache key to associate with the value.
    public func setValue(_ value: Value, forKey key: CacheKey) async {
        await setEntry(CacheEntry(value), forKey: key)
    }
}
