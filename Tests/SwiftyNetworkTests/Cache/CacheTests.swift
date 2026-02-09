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
