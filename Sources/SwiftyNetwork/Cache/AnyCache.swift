import Foundation

// MARK: - Type-Erased Cache

/// A type-erased cache that wraps any concrete cache implementation.
///
/// This allows for using different cache implementations interchangeably
/// without exposing the specific cache type.
public final class AnyCache<T: Sendable>: @unchecked Sendable {
    private let _getValue: (CacheKey) async -> T?
    private let _setValue: (T, CacheKey) async -> Void
    private let _removeValue: (CacheKey) async -> Void
    private let _removeAll: () async -> Void
    private let _timestamp: (CacheKey) async -> Date?

    /// Creates a type-erased cache wrapping the given cache implementation.
    ///
    /// - Parameter cache: The concrete cache implementation to wrap.
    public init<C: Cache>(_ cache: C) where C.Value == T {
        _getValue = cache.value(forKey:)
        _setValue = { value, key in await cache.setValue(value, forKey: key) }
        _removeValue = { key in await cache.removeValue(forKey: key) }
        _removeAll = { await cache.removeAll() }
        _timestamp = cache.timestamp(forKey:)
    }

    /// Retrieves a value from the cache for the given key.
    ///
    /// - Parameter key: The cache key to lookup.
    /// - Returns: The cached value if it exists, otherwise `nil`.
    public func value(forKey key: CacheKey) async -> T? { 
        await _getValue(key) 
    }
    
    /// Stores a value in the cache for the given key.
    ///
    /// - Parameters:
    ///   - value: The value to store in the cache.
    ///   - key: The cache key to associate with the value.
    public func setValue(_ value: T, forKey key: CacheKey) async { 
        await _setValue(value, key) 
    }
    
    /// Removes a value from the cache for the given key.
    ///
    /// - Parameter key: The cache key to remove.
    public func removeValue(forKey key: CacheKey) async { 
        await _removeValue(key) 
    }
    
    /// Removes all values from the cache.
    public func removeAll() async { 
        await _removeAll() 
    }
    
    /// Returns the timestamp when the value was last stored for the given key.
    ///
    /// - Parameter key: The cache key to inspect.
    /// - Returns: The stored timestamp if present, otherwise `nil`.
    public func timestamp(forKey key: CacheKey) async -> Date? {
        await _timestamp(key)
    }
}
