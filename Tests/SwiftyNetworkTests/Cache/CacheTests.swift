import Foundation
import Testing

@testable import SwiftyNetwork

@Test("Cache Key Creation")
func testCacheKeyCreation() {
    let simpleKey = CacheKey("test-key")
    #expect(simpleKey.rawValue == "test-key")
}

@Test("CacheKey endpoint keys sort query params")
func testCacheKeyEndpointSorting() {
    let key = CacheKey.endpoint("/users", parameters: ["b": "2", "a": "1"])
    #expect(key.rawValue == "/users?a=1&b=2")
}

@Test("CacheKey endpoint without parameters")
func testCacheKeyEndpointWithoutParams() {
    let key = CacheKey.endpoint("/users", parameters: [:])
    #expect(key.rawValue == "/users")
}

@Test("CacheKey conforms to Hashable")
func testCacheKeyHashable() {
    let key1 = CacheKey("test")
    let key2 = CacheKey("test")
    let key3 = CacheKey("different")

    #expect(key1 == key2)
    #expect(key1 != key3)

    var set = Set<CacheKey>()
    set.insert(key1)
    set.insert(key2)
    #expect(set.count == 1)

    set.insert(key3)
    #expect(set.count == 2)
}

@Test("CachePolicy decision logic")
func testCachePolicyDecisionLogic() {
    #expect(CachePolicy.returnCacheElseLoad.shouldUseCachedData(cacheAge: 999))
    #expect(CachePolicy.reloadIgnoringCache.shouldUseCachedData(cacheAge: 0) == false)
    #expect(CachePolicy.returnCacheIfNotExpired(maxAge: 10).shouldUseCachedData(cacheAge: 10))
    #expect(CachePolicy.returnCacheIfNotExpired(maxAge: 10).shouldUseCachedData(cacheAge: 11) == false)
}

@Test("InMemoryCache stores, removes, and timestamps values")
func testInMemoryCacheStoresAndRemoves() async {
    let cache = InMemoryCache<String>()
    let key = CacheKey("mem-key")
    let timestamp = Date(timeIntervalSince1970: 100)

    await cache.setValue("value", forKey: key, timestamp: timestamp)
    #expect(await cache.value(forKey: key) == "value")
    #expect(await cache.timestamp(forKey: key) == timestamp)

    await cache.removeValue(forKey: key)
    #expect(await cache.value(forKey: key) == nil)

    await cache.setValue("value2", forKey: key)
    await cache.removeAll()
    #expect(await cache.value(forKey: key) == nil)
}

@Test("AnyCache forwards calls to underlying cache")
func testAnyCacheForwardsCalls() async {
    let cache = RecordingCache<String>()
    let anyCache = AnyCache(cache)
    let key = CacheKey("any-cache")
    let timestamp = Date(timeIntervalSince1970: 200)

    await cache.setValue("value", forKey: key, timestamp: timestamp)
    _ = await anyCache.value(forKey: key)
    _ = await anyCache.timestamp(forKey: key)
    await anyCache.setValue("value2", forKey: key)
    await anyCache.removeValue(forKey: key)
    await anyCache.removeAll()

    let calls = await cache.callCounts
    #expect(calls.get == 1)
    #expect(calls.timestamp == 1)
    #expect(calls.set == 2)
    #expect(calls.remove == 1)
    #expect(calls.removeAll == 1)
}

@Test("LayeredCache promotes persistent values with timestamps")
func testLayeredCachePromotesPersistentValue() async {
    let memoryCache = InMemoryCache<String>()
    let persistentCache = TestPersistentCache<String>()
    let layeredCache = LayeredCache(memoryCache: memoryCache, persistentCache: persistentCache)
    let key = CacheKey("layered-value")
    let timestamp = Date(timeIntervalSince1970: 123)

    await persistentCache.setValue("value", forKey: key, timestamp: timestamp)

    let value = await layeredCache.value(forKey: key)
    let layeredTimestamp = await layeredCache.timestamp(forKey: key)
    let memoryTimestamp = await memoryCache.timestamp(forKey: key)

    #expect(value == "value")
    #expect(layeredTimestamp == timestamp)
    #expect(memoryTimestamp == timestamp)
}

@Test("LayeredCache uses memory values without persistent access")
func testLayeredCacheUsesMemoryValue() async {
    let memoryCache = InMemoryCache<String>()
    let persistentCache = RecordingCache<String>()
    let layeredCache = LayeredCache(memoryCache: memoryCache, persistentCache: persistentCache)
    let key = CacheKey("memory-first")

    await memoryCache.setValue("value", forKey: key)
    let value = await layeredCache.value(forKey: key)

    #expect(value == "value")
    let calls = await persistentCache.callCounts
    #expect(calls.get == 0)
}

@Test("LayeredCache remove propagates to both layers")
func testLayeredCacheRemovePropagates() async {
    let memoryCache = InMemoryCache<String>()
    let persistentCache = RecordingCache<String>()
    let layeredCache = LayeredCache(memoryCache: memoryCache, persistentCache: persistentCache)
    let key = CacheKey("remove-key")

    await layeredCache.setValue("value", forKey: key)
    await layeredCache.removeValue(forKey: key)

    #expect(await memoryCache.value(forKey: key) == nil)
    let calls = await persistentCache.callCounts
    #expect(calls.remove == 1)
}

private actor TestPersistentCache<Value: Sendable>: PersistentCache {
    private var storage: [CacheKey: (Value, Date)] = [:]

    func value(forKey key: CacheKey) async -> Value? {
        storage[key]?.0
    }

    func setValue(_ value: Value, forKey key: CacheKey) async {
        storage[key] = (value, Date())
    }

    func setValue(_ value: Value, forKey key: CacheKey, timestamp: Date) async {
        storage[key] = (value, timestamp)
    }

    func removeValue(forKey key: CacheKey) async {
        storage.removeValue(forKey: key)
    }

    func removeAll() async {
        storage.removeAll()
    }

    func timestamp(forKey key: CacheKey) async -> Date? {
        storage[key]?.1
    }
}

private actor RecordingCache<Value: Sendable>: TimestampedCache {
    private var storage: [CacheKey: (Value, Date)] = [:]
    private(set) var callCounts = (get: 0, set: 0, remove: 0, removeAll: 0, timestamp: 0)

    func value(forKey key: CacheKey) async -> Value? {
        callCounts.get += 1
        return storage[key]?.0
    }

    func setValue(_ value: Value, forKey key: CacheKey) async {
        callCounts.set += 1
        storage[key] = (value, Date())
    }

    func setValue(_ value: Value, forKey key: CacheKey, timestamp: Date) async {
        callCounts.set += 1
        storage[key] = (value, timestamp)
    }

    func removeValue(forKey key: CacheKey) async {
        callCounts.remove += 1
        storage.removeValue(forKey: key)
    }

    func removeAll() async {
        callCounts.removeAll += 1
        storage.removeAll()
    }

    func timestamp(forKey key: CacheKey) async -> Date? {
        callCounts.timestamp += 1
        return storage[key]?.1
    }
}

// MARK: - Additional InMemoryCache Tests

@Test("InMemoryCache removes expired entries")
func inMemoryCacheRemovesExpired() async {
    let cache = InMemoryCache<String>()
    let key1 = CacheKey("old")
    let key2 = CacheKey("new")

    await cache.setValue("old-value", forKey: key1)
    try? await Task.sleep(for: .milliseconds(100))
    await cache.setValue("new-value", forKey: key2)

    await cache.removeExpiredEntries(maxAge: 0.05)

    let oldValue = await cache.value(forKey: key1)
    let newValue = await cache.value(forKey: key2)

    #expect(oldValue == nil)
    #expect(newValue == "new-value")
}

@Test("InMemoryCache removes entries older than specified age")
func inMemoryCacheRemovesOlderThan() async {
    let cache = InMemoryCache<String>()
    let key = CacheKey("test")

    await cache.setValue("value", forKey: key)
    try? await Task.sleep(for: .milliseconds(100))

    await cache.removeEntries(olderThan: 0.05)

    let value = await cache.value(forKey: key)
    #expect(value == nil)
}

@Test("InMemoryCache reports count")
func inMemoryCacheReportsCount() async {
    let cache = InMemoryCache<String>()

    #expect(await cache.count() == 0)

    await cache.setValue("value1", forKey: CacheKey("key1"))
    await cache.setValue("value2", forKey: CacheKey("key2"))

    #expect(await cache.count() == 2)

    await cache.removeValue(forKey: CacheKey("key1"))

    #expect(await cache.count() == 1)
}

@Test("InMemoryCache with maxSize evicts LRU entries")
func inMemoryCacheEvictsLRU() async {
    let cache = InMemoryCache<String>(maxSize: 2)
    let key1 = CacheKey("key1")
    let key2 = CacheKey("key2")
    let key3 = CacheKey("key3")

    await cache.setValue("value1", forKey: key1)
    await cache.setValue("value2", forKey: key2)
    await cache.setValue("value3", forKey: key3)

    let value1 = await cache.value(forKey: key1)
    let value2 = await cache.value(forKey: key2)
    let value3 = await cache.value(forKey: key3)

    #expect(value1 == nil)
    #expect(value2 == "value2")
    #expect(value3 == "value3")
}

// MARK: - Concurrent Cache Access Tests

@Test("InMemoryCache handles concurrent reads and writes safely")
func inMemoryCacheConcurrentAccess() async {
    let cache = InMemoryCache<Int>()

    // Perform many concurrent writes followed by reads
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<100 {
            group.addTask {
                await cache.setValue(i, forKey: CacheKey("key-\(i)"))
            }
        }
    }

    // All 100 values should be present
    let count = await cache.count()
    #expect(count == 100)

    // Concurrent reads should all succeed
    await withTaskGroup(of: Int?.self) { group in
        for i in 0..<100 {
            group.addTask {
                await cache.value(forKey: CacheKey("key-\(i)"))
            }
        }
        var results = [Int?]()
        for await result in group {
            results.append(result)
        }
        let nonNilCount = results.compactMap { $0 }.count
        #expect(nonNilCount == 100)
    }
}

@Test("InMemoryCache concurrent writes to same key produce consistent state")
func inMemoryCacheConcurrentWritesSameKey() async {
    let cache = InMemoryCache<Int>()
    let key = CacheKey("same-key")

    // Write concurrently to the same key
    await withTaskGroup(of: Void.self) { group in
        for i in 0..<50 {
            group.addTask {
                await cache.setValue(i, forKey: key)
            }
        }
    }

    // Exactly one value should be stored (last writer wins)
    let value = await cache.value(forKey: key)
    #expect(value != nil)
    let count = await cache.count()
    #expect(count == 1)
}

// MARK: - LayeredCache removeAll Tests

@Test("LayeredCache removeAll clears both memory and persistent layers")
func testLayeredCacheRemoveAllPropagates() async {
    let memoryCache = InMemoryCache<String>()
    let persistentCache = RecordingCache<String>()
    let layeredCache = LayeredCache(memoryCache: memoryCache, persistentCache: persistentCache)

    await layeredCache.setValue("v1", forKey: CacheKey("k1"))
    await layeredCache.setValue("v2", forKey: CacheKey("k2"))
    await layeredCache.setValue("v3", forKey: CacheKey("k3"))

    // Verify values exist
    #expect(await memoryCache.value(forKey: CacheKey("k1")) == "v1")

    await layeredCache.removeAll()

    // Memory should be cleared
    #expect(await memoryCache.value(forKey: CacheKey("k1")) == nil)
    #expect(await memoryCache.value(forKey: CacheKey("k2")) == nil)
    #expect(await memoryCache.value(forKey: CacheKey("k3")) == nil)

    // Persistent removeAll should have been called
    let calls = await persistentCache.callCounts
    #expect(calls.removeAll == 1)
}

@Test("LayeredCache set propagates to both layers")
func testLayeredCacheSetPropagates() async {
    let memoryCache = InMemoryCache<String>()
    let persistentCache = RecordingCache<String>()
    let layeredCache = LayeredCache(memoryCache: memoryCache, persistentCache: persistentCache)

    await layeredCache.setValue("value", forKey: CacheKey("key"))

    #expect(await memoryCache.value(forKey: CacheKey("key")) == "value")
    let calls = await persistentCache.callCounts
    #expect(calls.set == 1)
}

@Test("LayeredCache timestamp falls back to persistent layer")
func testLayeredCacheTimestampFallback() async {
    let memoryCache = InMemoryCache<String>()
    let persistentCache = TestPersistentCache<String>()
    let layeredCache = LayeredCache(memoryCache: memoryCache, persistentCache: persistentCache)
    let key = CacheKey("timestamp-fallback")
    let timestamp = Date(timeIntervalSince1970: 500)

    // Only set in persistent layer
    await persistentCache.setValue("value", forKey: key, timestamp: timestamp)

    // First call to value() promotes to memory, so timestamp should be available
    _ = await layeredCache.value(forKey: key)
    let layeredTimestamp = await layeredCache.timestamp(forKey: key)
    #expect(layeredTimestamp == timestamp)
}

// MARK: - AnyCache Edge Cases

@Test("AnyCache wrapping InMemoryCache preserves values correctly")
func testAnyCachePreservesValues() async {
    let inner = InMemoryCache<String>()
    let anyCache = AnyCache(inner)
    let key = CacheKey("any-preserve")

    await anyCache.setValue("hello", forKey: key)
    let value = await anyCache.value(forKey: key)
    #expect(value == "hello")

    let ts = await anyCache.timestamp(forKey: key)
    #expect(ts != nil)

    await anyCache.removeValue(forKey: key)
    #expect(await anyCache.value(forKey: key) == nil)
}

@Test("AnyCache removeAll clears all entries")
func testAnyCacheRemoveAll() async {
    let inner = InMemoryCache<Int>()
    let anyCache = AnyCache(inner)

    await anyCache.setValue(1, forKey: CacheKey("a"))
    await anyCache.setValue(2, forKey: CacheKey("b"))

    await anyCache.removeAll()

    #expect(await anyCache.value(forKey: CacheKey("a")) == nil)
    #expect(await anyCache.value(forKey: CacheKey("b")) == nil)
}
