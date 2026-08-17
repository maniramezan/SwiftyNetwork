import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("SingleFlightCache Tests")
struct SingleFlightCacheTests {

    @Test("value(forKey:) and setValue pass through to the wrapped cache")
    func passThroughReadWrite() async {
        let cache = SingleFlightCache(InMemoryCache<String>())
        let key = CacheKey("k")

        #expect(await cache.value(forKey: key) == nil)
        await cache.setValue("hello", forKey: key)
        #expect(await cache.value(forKey: key) == "hello")
    }

    @Test("removeValue and removeAll pass through to the wrapped cache")
    func passThroughRemoval() async {
        let cache = SingleFlightCache(InMemoryCache<String>())
        await cache.setValue("a", forKey: CacheKey("a"))
        await cache.setValue("b", forKey: CacheKey("b"))

        await cache.removeValue(forKey: CacheKey("a"))
        #expect(await cache.value(forKey: CacheKey("a")) == nil)
        #expect(await cache.value(forKey: CacheKey("b")) == "b")

        await cache.removeAll()
        #expect(await cache.value(forKey: CacheKey("b")) == nil)
    }

    @Test("value(forKey:orFetch:) returns a cached value without calling fetch")
    func returnsCachedValueWithoutFetching() async throws {
        let cache = SingleFlightCache(InMemoryCache<String>())
        await cache.setValue("cached", forKey: CacheKey("k"))
        let fetchCount = Counter()

        let result = try await cache.value(forKey: CacheKey("k")) {
            await fetchCount.increment()
            return "fetched"
        }

        #expect(result == "cached")
        #expect(await fetchCount.value == 0)
    }

    @Test("value(forKey:orFetch:) fetches and caches on a miss")
    func fetchesAndCachesOnMiss() async throws {
        let cache = SingleFlightCache(InMemoryCache<String>())
        let fetchCount = Counter()

        let result = try await cache.value(forKey: CacheKey("k")) {
            await fetchCount.increment()
            return "fetched"
        }

        #expect(result == "fetched")
        #expect(await fetchCount.value == 1)
        #expect(await cache.value(forKey: CacheKey("k")) == "fetched")
    }

    @Test("Concurrent misses for the same key coalesce into a single fetch")
    func concurrentMissesCoalesce() async throws {
        let cache = SingleFlightCache(InMemoryCache<String>())
        let fetchCount = Counter()
        let gate = Gate()

        async let first = cache.value(forKey: CacheKey("k")) {
            await fetchCount.increment()
            await gate.wait()
            return "fetched"
        }
        async let second = cache.value(forKey: CacheKey("k")) {
            await fetchCount.increment()
            await gate.wait()
            return "fetched"
        }

        // Ensure the first call has actually started (and is blocked on the
        // gate) before releasing it, so the second call is guaranteed to
        // observe an in-flight fetch rather than racing to start its own.
        while await fetchCount.value == 0 { await Task.yield() }
        await gate.open()

        let (firstResult, secondResult) = try await (first, second)

        #expect(firstResult == "fetched")
        #expect(secondResult == "fetched")
        #expect(await fetchCount.value == 1)
    }

    @Test("A failed fetch is not cached, so the next call retries it")
    func failedFetchIsNotCached() async {
        struct FetchError: Error {}
        let cache = SingleFlightCache(InMemoryCache<String>())
        let fetchCount = Counter()

        await #expect(throws: FetchError.self) {
            try await cache.value(forKey: CacheKey("k")) {
                await fetchCount.increment()
                throw FetchError()
            }
        }
        #expect(await cache.value(forKey: CacheKey("k")) == nil)

        let result = try? await cache.value(forKey: CacheKey("k")) {
            await fetchCount.increment()
            return "recovered"
        }

        #expect(result == "recovered")
        #expect(await fetchCount.value == 2)
    }

    @Test("timestamp(forKey:) passes through to the wrapped cache")
    func passThroughTimestamp() async {
        let cache = SingleFlightCache(InMemoryCache<String>())
        #expect(await cache.timestamp(forKey: CacheKey("k")) == nil)

        await cache.setValue("hello", forKey: CacheKey("k"))

        #expect(await cache.timestamp(forKey: CacheKey("k")) != nil)
    }

    @Test("removeValue cancels an in-flight fetch for that key")
    func removeValueCancelsInFlightFetch() async {
        let cache = SingleFlightCache(InMemoryCache<String>())
        let started = Counter()

        async let result: String? = try? await cache.value(forKey: CacheKey("k")) {
            await started.increment()
            try await Task.sleep(for: .seconds(10))
            return "should not be reached"
        }

        while await started.value == 0 { await Task.yield() }
        await cache.removeValue(forKey: CacheKey("k"))

        #expect(await result == nil)
        #expect(await cache.value(forKey: CacheKey("k")) == nil)
    }

    @Test("Fetches for different keys run independently")
    func differentKeysDoNotCoalesce() async throws {
        let cache = SingleFlightCache(InMemoryCache<String>())
        let fetchCount = Counter()

        async let a = cache.value(forKey: CacheKey("a")) {
            await fetchCount.increment()
            return "a-value"
        }
        async let b = cache.value(forKey: CacheKey("b")) {
            await fetchCount.increment()
            return "b-value"
        }

        let (aResult, bResult) = try await (a, b)

        #expect(aResult == "a-value")
        #expect(bResult == "b-value")
        #expect(await fetchCount.value == 2)
    }
}

/// A small `Sendable` counter for tests that need to observe how many times
/// a closure ran across concurrent tasks.
actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
