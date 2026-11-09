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

@Test("CacheKey endpoint parameters cannot collide with separators")
func testCacheKeyEndpointEscaping() {
    let combined = CacheKey.endpoint("/search", parameters: ["q": "red&sort=asc"])
    let separate = CacheKey.endpoint("/search", parameters: ["q": "red", "sort": "asc"])
    let equalsInKey = CacheKey.endpoint("/search", parameters: ["q=red": "asc"])

    #expect(combined.rawValue == "/search?q=red%26sort%3Dasc")
    #expect(combined != separate)
    #expect(equalsInKey.rawValue == "/search?q%3Dred=asc")
    #expect(equalsInKey != CacheKey.endpoint("/search", parameters: ["q": "red=asc"]))
}

@Test("CacheKey encodes raw Unicode and reserved characters with Foundation")
func testCacheKeyEndpointUnicodeEscaping() {
    let key = CacheKey.endpoint("/search", parameters: ["q": "é🙂 +/%20"])
    #expect(key.rawValue == "/search?q=%C3%A9%F0%9F%99%82%20%2B%2F%2520")
    let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    #expect(CacheKey.endpoint("/search", parameters: ["q": unreserved]).rawValue == "/search?q=\(unreserved)")
    #expect(CacheKey.endpoint("/search", parameters: ["q": ""]).rawValue == "/search?q=")
}

@Test("CacheKey endpoint without parameters")
func testCacheKeyEndpointWithoutParams() {
    let key = CacheKey.endpoint("/users", parameters: [:])
    #expect(key.rawValue == "/users")
}

@Test("CacheKey initializes from a URL using its absolute string")
func testCacheKeyFromURL() {
    let url = URL(string: "https://api.example.com/users/123")!
    let key = CacheKey(url: url)
    #expect(key.rawValue == "https://api.example.com/users/123")
}

@Test("CacheKey initializes from components with a custom separator")
func testCacheKeyFromComponents() {
    let key = CacheKey(components: ["users", "123", "posts"])
    #expect(key.rawValue == "users:123:posts")

    let customSeparator = CacheKey(components: ["a", "b"], separator: "/")
    #expect(customSeparator.rawValue == "a/b")
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
    #expect(CachePolicy.returnCacheElseLoad.shouldUseCachedData(cacheAge: .seconds(999)))
    #expect(CachePolicy.reloadIgnoringCache.shouldUseCachedData(cacheAge: .seconds(0)) == false)
    #expect(CachePolicy.returnCacheIfNotExpired(maxAge: .seconds(10)).shouldUseCachedData(cacheAge: .seconds(10)))
    #expect(
        CachePolicy.returnCacheIfNotExpired(maxAge: .seconds(10)).shouldUseCachedData(cacheAge: .seconds(11)) == false)
}

@Test("InMemoryCache stores, removes, and timestamps values")
func testInMemoryCacheStoresAndRemoves() async {
    let cache = InMemoryCache<String>()
    let key = CacheKey("mem-key")
    let timestamp = Date(timeIntervalSince1970: 100)

    await cache.setEntry(CacheEntry("value", timestamp: timestamp), forKey: key)
    #expect(await cache.value(forKey: key) == "value")
    #expect(await cache.entry(forKey: key) == CacheEntry("value", timestamp: timestamp))

    await cache.removeValue(forKey: key)
    #expect(await cache.value(forKey: key) == nil)

    await cache.setValue("value2", forKey: key)
    await cache.removeAll()
    #expect(await cache.value(forKey: key) == nil)
}

@Test("value(forKey:) and setValue(_:forKey:) go through the entry requirements of an existential cache")
func testCacheConveniencesForwardThroughExistential() async {
    let recording = RecordingCache<String>()
    let cache: any Cache<String> = recording
    let key = CacheKey("any-cache")

    let before = Date()
    await cache.setValue("value", forKey: key)
    #expect(await cache.value(forKey: key) == "value")
    let entry = await cache.entry(forKey: key)
    #expect(entry?.value == "value")
    #expect((entry?.timestamp ?? .distantPast) >= before)
    await cache.removeValue(forKey: key)
    await cache.removeAll()

    let calls = await recording.callCounts
    #expect(calls.get == 2)
    #expect(calls.set == 1)
    #expect(calls.remove == 1)
    #expect(calls.removeAll == 1)
}

@Test("CacheEntry.age measures the time since the timestamp")
func testCacheEntryAge() {
    let entry = CacheEntry("value", timestamp: Date(timeIntervalSince1970: 100))
    #expect(entry.age(at: Date(timeIntervalSince1970: 160)) == .seconds(60))
}

@Test("LayeredCache promotes persistent values with timestamps")
func testLayeredCachePromotesPersistentValue() async {
    let memoryCache = InMemoryCache<String>()
    let persistentCache = TestPersistentCache<String>()
    let layeredCache = LayeredCache(memoryCache: memoryCache, persistentCache: persistentCache)
    let key = CacheKey("layered-value")
    let timestamp = Date(timeIntervalSince1970: 123)

    await persistentCache.setEntry(CacheEntry("value", timestamp: timestamp), forKey: key)

    let value = await layeredCache.value(forKey: key)
    let layeredTimestamp = await layeredCache.entry(forKey: key)?.timestamp
    let memoryTimestamp = await memoryCache.entry(forKey: key)?.timestamp

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

@Test("LayeredCache with only a memory layer stores and retrieves values")
func testLayeredCacheMemoryOnlyInit() async {
    let memoryCache = InMemoryCache<String>()
    let layeredCache = LayeredCache(memoryCache: memoryCache)
    let key = CacheKey("memory-only")

    await layeredCache.setValue("value", forKey: key)

    #expect(await layeredCache.value(forKey: key) == "value")
    #expect(await layeredCache.entry(forKey: key) != nil)
}

@Test("LayeredCache with only a memory layer reports a miss for absent keys")
func testLayeredCacheMemoryOnlyMiss() async {
    let layeredCache = LayeredCache(memoryCache: InMemoryCache<String>())
    let key = CacheKey("memory-only-miss")

    #expect(await layeredCache.value(forKey: key) == nil)
    #expect(await layeredCache.entry(forKey: key) == nil)
}

@Test("LayeredCache reports a miss when neither layer has the value")
func testLayeredCacheMissesBothLayers() async {
    let memoryCache = InMemoryCache<String>()
    let persistentCache = TestPersistentCache<String>()
    let layeredCache = LayeredCache(memoryCache: memoryCache, persistentCache: persistentCache)
    let key = CacheKey("miss-both-layers")

    #expect(await layeredCache.value(forKey: key) == nil)
    #expect(await layeredCache.entry(forKey: key) == nil)
}

private actor TestPersistentCache<Value: Sendable>: Cache {
    private var storage: [CacheKey: CacheEntry<Value>] = [:]

    func entry(forKey key: CacheKey) async -> CacheEntry<Value>? {
        storage[key]
    }

    func setEntry(_ entry: CacheEntry<Value>, forKey key: CacheKey) async {
        storage[key] = entry
    }

    func removeValue(forKey key: CacheKey) async {
        storage.removeValue(forKey: key)
    }

    func removeAll() async {
        storage.removeAll()
    }
}

private actor RecordingCache<Value: Sendable>: Cache {
    private var storage: [CacheKey: CacheEntry<Value>] = [:]
    private(set) var callCounts = (get: 0, set: 0, remove: 0, removeAll: 0)

    func entry(forKey key: CacheKey) async -> CacheEntry<Value>? {
        callCounts.get += 1
        return storage[key]
    }

    func setEntry(_ entry: CacheEntry<Value>, forKey key: CacheKey) async {
        callCounts.set += 1
        storage[key] = entry
    }

    func removeValue(forKey key: CacheKey) async {
        callCounts.remove += 1
        storage.removeValue(forKey: key)
    }

    func removeAll() async {
        callCounts.removeAll += 1
        storage.removeAll()
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

    await cache.removeEntries(olderThan: .seconds(0.05))

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

    await cache.removeEntries(olderThan: .seconds(0.05))

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
    await persistentCache.setEntry(CacheEntry("value", timestamp: timestamp), forKey: key)

    // First call to value() promotes to memory, so timestamp should be available
    _ = await layeredCache.value(forKey: key)
    let layeredTimestamp = await layeredCache.entry(forKey: key)?.timestamp
    #expect(layeredTimestamp == timestamp)
}

@Test("InMemoryCache evicts by access order, not insertion order")
func inMemoryCacheEvictsByAccessOrder() async {
    let cache = InMemoryCache<String>(maxSize: 2)
    await cache.setValue("value1", forKey: CacheKey("key1"))
    await cache.setValue("value2", forKey: CacheKey("key2"))
    // Touch key1 so key2 becomes the least recently used entry.
    _ = await cache.value(forKey: CacheKey("key1"))
    await cache.setValue("value3", forKey: CacheKey("key3"))

    #expect(await cache.value(forKey: CacheKey("key1")) == "value1")
    #expect(await cache.value(forKey: CacheKey("key2")) == nil)
    #expect(await cache.value(forKey: CacheKey("key3")) == "value3")
}

@Test("InMemoryCache treats a negative maxSize as zero")
func inMemoryCacheNegativeMaxSize() async {
    let cache = InMemoryCache<String>(maxSize: -1)
    await cache.setValue("value", forKey: CacheKey("key"))

    #expect(await cache.count() == 0)
}

@Test("CacheKey supports string literals and describes itself by raw value")
func cacheKeyStringLiteral() {
    let key: CacheKey = "user:123:profile"

    #expect(key == CacheKey("user:123:profile"))
    #expect(key.description == "user:123:profile")
}

// MARK: - Cost Limits

@Test("InMemoryCache maxBytes evicts least recently used entries until under budget")
func inMemoryCacheMaxBytesEvictsLRU() async {
    let cache = InMemoryCache<Data>(maxBytes: 10)
    await cache.setValue(Data(count: 4), forKey: "a")
    await cache.setValue(Data(count: 4), forKey: "b")
    _ = await cache.value(forKey: "a")  // "b" is now least recently used.
    await cache.setValue(Data(count: 4), forKey: "c")

    #expect(await cache.value(forKey: "b") == nil)
    #expect(await cache.value(forKey: "a") != nil)
    #expect(await cache.value(forKey: "c") != nil)
    #expect(await cache.totalCost() == 8)
}

@Test("InMemoryCache replacing a value updates the total cost")
func inMemoryCacheReplaceUpdatesCost() async {
    let cache = InMemoryCache<Data>(maxBytes: 100)
    await cache.setValue(Data(count: 30), forKey: "a")
    await cache.setValue(Data(count: 10), forKey: "a")

    #expect(await cache.totalCost() == 10)
    #expect(await cache.count() == 1)
}

@Test("InMemoryCache cost accounting does not overflow at Int.max")
func inMemoryCacheCostDoesNotOverflow() async {
    let cache = InMemoryCache<Int>(maxCost: Int.max) { $0 }
    await cache.setValue(Int.max, forKey: "large")
    await cache.setValue(1, forKey: "small")

    #expect(await cache.value(forKey: "large") == nil)
    #expect(await cache.value(forKey: "small") == 1)
    #expect(await cache.totalCost() == 1)
}

@Test("InMemoryCache evicts a single value costlier than the whole budget")
func inMemoryCacheEvictsOversizedValue() async {
    let cache = InMemoryCache<Data>(maxBytes: 10)
    await cache.setValue(Data(count: 3), forKey: "small")
    await cache.setValue(Data(count: 11), forKey: "huge")

    #expect(await cache.value(forKey: "huge") == nil)
    #expect(await cache.value(forKey: "small") == nil)
    #expect(await cache.totalCost() == 0)
}

@Test("InMemoryCache removals release their cost")
func inMemoryCacheRemovalsReleaseCost() async {
    let cache = InMemoryCache<String>(maxCost: 100) { $0.count }
    await cache.setValue("12345", forKey: "a")
    await cache.setEntry(CacheEntry("123", timestamp: Date().addingTimeInterval(-600)), forKey: "b")
    await cache.setValue("1", forKey: "c")
    #expect(await cache.totalCost() == 9)

    await cache.removeValue(forKey: "a")
    #expect(await cache.totalCost() == 4)

    await cache.removeEntries(olderThan: .seconds(60))
    #expect(await cache.totalCost() == 1)

    await cache.removeAll()
    #expect(await cache.totalCost() == 0)
}

@Test("InMemoryCache applies entry-count and cost limits together")
func inMemoryCacheCountAndCostLimits() async {
    let cache = InMemoryCache<Data>(maxSize: 2, maxBytes: 100)
    await cache.setValue(Data(count: 1), forKey: "a")
    await cache.setValue(Data(count: 1), forKey: "b")
    await cache.setValue(Data(count: 1), forKey: "c")

    #expect(await cache.count() == 2)
    #expect(await cache.value(forKey: "a") == nil)
}
