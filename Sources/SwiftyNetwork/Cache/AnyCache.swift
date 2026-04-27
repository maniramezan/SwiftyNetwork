import Foundation

// MARK: - Type-Erased Cache

/// A type-erased cache that wraps any concrete cache implementation.
///
/// Use ``AnyCache`` to pass different cache implementations through APIs that
/// don't want to expose a concrete cache type. The wrapper is `Sendable`
/// because all of its stored work items are `@Sendable` closures and the
/// underlying cache must itself be `Sendable`.
public struct AnyCache<T: Sendable>: Cache {
    public typealias Value = T

    private let _getValue: @Sendable (CacheKey) async -> T?
    private let _setValue: @Sendable (T, CacheKey) async -> Void
    private let _removeValue: @Sendable (CacheKey) async -> Void
    private let _removeAll: @Sendable () async -> Void
    private let _timestamp: @Sendable (CacheKey) async -> Date?

    /// Creates a type-erased cache wrapping the given cache implementation.
    ///
    /// - Parameter cache: The concrete cache implementation to wrap.
    public init<C: Cache>(_ cache: C) where C.Value == T {
        _getValue = { key in await cache.value(forKey: key) }
        _setValue = { value, key in await cache.setValue(value, forKey: key) }
        _removeValue = { key in await cache.removeValue(forKey: key) }
        _removeAll = { await cache.removeAll() }
        _timestamp = { key in await cache.timestamp(forKey: key) }
    }

    /// Retrieves a value from the cache for the given key.
    public func value(forKey key: CacheKey) async -> T? {
        await _getValue(key)
    }

    /// Stores a value in the cache for the given key.
    public func setValue(_ value: T, forKey key: CacheKey) async {
        await _setValue(value, key)
    }

    /// Removes a value from the cache for the given key.
    public func removeValue(forKey key: CacheKey) async {
        await _removeValue(key)
    }

    /// Removes all values from the cache.
    public func removeAll() async {
        await _removeAll()
    }

    /// Returns the timestamp when the value was last stored for the given key.
    public func timestamp(forKey key: CacheKey) async -> Date? {
        await _timestamp(key)
    }
}
