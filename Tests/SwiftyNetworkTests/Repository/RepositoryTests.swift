import Foundation
import TestCommons
import Testing

@testable import SwiftyNetwork

@Test("GenericRepository accepts any Cache, including a LayeredCache")
func testRepositoryAcceptsLayeredCache() async throws {
    let memory = InMemoryCache<TestUser>()
    let layered = LayeredCache(memoryCache: memory)
    let networkUser = TestUser(id: "1", name: "Sam", email: "sam@example.com")
    let network = StubUserClient(result: .success(networkUser))
    let repository = GenericRepository(client: network, cache: layered)
    let key = CacheKey("layered-repo")

    let fetched = try await repository.fetch(using: TestEndpoint(), cacheKey: key, policy: .returnCacheElseLoad)

    #expect(fetched == networkUser)
    #expect(await memory.value(forKey: key) == networkUser)
}

@Test("GenericRepository returns cached data when available")
func testRepositoryReturnsCachedData() async throws {
    let cache = InMemoryCache<TestUser>()
    let network = StubUserClient(result: .success(TestUser(id: "2", name: "Net", email: "net@example.com")))
    let repository = GenericRepository(client: network, cache: cache)
    let key = CacheKey("repo-cache")
    let cached = TestUser(id: "cached", name: "Cache", email: "cache@example.com")
    await cache.setValue(cached, forKey: key)

    let fetched = try await repository.fetch(using: TestEndpoint(), cacheKey: key, policy: .returnCacheElseLoad)

    #expect(fetched == cached)
    let count = await network.requestCount
    #expect(count == 0)
}

@Test("GenericRepository loads from network and caches on miss")
func testRepositoryLoadsFromNetworkOnMiss() async throws {
    let cache = InMemoryCache<TestUser>()
    let networkUser = TestUser(id: "3", name: "Remote", email: "remote@example.com")
    let network = StubUserClient(result: .success(networkUser))
    let repository = GenericRepository(client: network, cache: cache)
    let key = CacheKey("repo-miss")

    let fetched = try await repository.fetch(using: TestEndpoint(), cacheKey: key, policy: .returnCacheElseLoad)

    #expect(fetched == networkUser)
    #expect(await cache.value(forKey: key) == networkUser)
    let count = await network.requestCount
    #expect(count == 1)
}

@Test("GenericRepository reloadIgnoringCache always hits network")
func testRepositoryReloadIgnoringCache() async throws {
    let cache = InMemoryCache<TestUser>()
    let cached = TestUser(id: "cached", name: "Cache", email: "cache@example.com")
    let networkUser = TestUser(id: "4", name: "Fresh", email: "fresh@example.com")
    await cache.setValue(cached, forKey: CacheKey("reload"))
    let network = StubUserClient(result: .success(networkUser))
    let repository = GenericRepository(client: network, cache: cache)
    let key = CacheKey("reload")

    let fetched = try await repository.fetch(using: TestEndpoint(), cacheKey: key, policy: .reloadIgnoringCache)

    #expect(fetched == networkUser)
    #expect(await cache.value(forKey: key) == networkUser)
    let count = await network.requestCount
    #expect(count == 1)
}

@Test("GenericRepository returns cache when not expired")
func testRepositoryReturnsCacheIfNotExpired() async throws {
    let cache = InMemoryCache<TestUser>()
    let user = TestUser(id: "5", name: "FreshCache", email: "freshcache@example.com")
    let key = CacheKey("not-expired")
    let now = Date()
    await cache.setEntry(CacheEntry(user, timestamp: now), forKey: key)
    let network = StubUserClient(result: .success(TestUser(id: "net", name: "Net", email: "net@example.com")))
    let repository = GenericRepository(client: network, cache: cache)

    let fetched = try await repository.fetch(
        using: TestEndpoint(),
        cacheKey: key,
        policy: .returnCacheIfNotExpired(maxAge: .seconds(60))
    )

    #expect(fetched == user)
    let count = await network.requestCount
    #expect(count == 0)
}

@Test("GenericRepository refreshes cache when expired")
func testRepositoryRefreshesWhenExpired() async throws {
    let cache = InMemoryCache<TestUser>()
    let expired = TestUser(id: "expired", name: "Old", email: "old@example.com")
    let key = CacheKey("expired")
    await cache.setEntry(CacheEntry(expired, timestamp: Date(timeIntervalSince1970: 0)), forKey: key)
    let networkUser = TestUser(id: "6", name: "New", email: "new@example.com")
    let network = StubUserClient(result: .success(networkUser))
    let repository = GenericRepository(client: network, cache: cache)

    let fetched = try await repository.fetch(
        using: TestEndpoint(),
        cacheKey: key,
        policy: .returnCacheIfNotExpired(maxAge: .seconds(1))
    )

    #expect(fetched == networkUser)
    #expect(await cache.value(forKey: key) == networkUser)
    let count = await network.requestCount
    #expect(count == 1)
}

@Test("GenericRepository surfaces network errors")
func testRepositoryPropagatesNetworkError() async {
    let cache = InMemoryCache<TestUser>()
    let network = StubUserClient(result: .failure(TestRepositoryError.networkFailure))
    let repository = GenericRepository(client: network, cache: cache)
    let key = CacheKey("error")

    await #expect {
        try await repository.fetch(using: TestEndpoint(), cacheKey: key, policy: .reloadIgnoringCache)
    } throws: { error in
        error is TestRepositoryError
    }
}

@Test("reloadElseReturnCache reports cached data and its original timestamp after a failure")
func testRepositoryReportsCacheFallback() async throws {
    let cache = InMemoryCache<TestUser>()
    let key: CacheKey = "reload-else-cache"
    let cached = TestUser(id: "cached", name: "Saved", email: "saved@example.com")
    let written = Date(timeIntervalSince1970: 1_000)
    await cache.setEntry(CacheEntry(cached, timestamp: written), forKey: key)
    let network = StubUserClient(result: .failure(TestRepositoryError.networkFailure))
    let repository = GenericRepository(client: network, cache: cache)

    let result = try await repository.fetchResult(
        using: TestEndpoint(),
        cacheKey: key,
        policy: .reloadElseReturnCache
    )

    #expect(result.value == cached)
    #expect(result.source == .cache)
    #expect(result.timestamp == written)
    #expect(result.age(at: Date(timeIntervalSince1970: 1_060)) == .seconds(60))
}

@Test("returnCacheAndRevalidate returns stale data while refreshing it in the background")
func testRepositoryStaleWhileRevalidate() async throws {
    let cache = InMemoryCache<TestUser>()
    let key: CacheKey = "stale-while-revalidate"
    let stale = TestUser(id: "stale", name: "Old", email: "old@example.com")
    let fresh = TestUser(id: "fresh", name: "New", email: "new@example.com")
    let written = Date(timeIntervalSince1970: 1_000)
    await cache.setEntry(CacheEntry(stale, timestamp: written), forKey: key)
    let network = StubUserClient(result: .success(fresh))
    let repository = GenericRepository(client: network, cache: cache)

    let result = try await repository.fetchResult(
        using: TestEndpoint(),
        cacheKey: key,
        policy: .returnCacheAndRevalidate(maxAge: .seconds(60))
    )
    _ = try await waitUntil(
        timeout: testTimeout,
        operation: { await cache.value(forKey: key) },
        matching: { $0 == fresh }
    )

    #expect(result.value == stale)
    #expect(result.source == .cache)
    #expect(result.timestamp == written)
    #expect(await network.requestCount == 1)
}

private enum TestRepositoryError: Error {
    case networkFailure
}

private actor StubUserClient: APIClient {
    private let result: Result<TestUser, Error>
    private(set) var requestCount = 0

    init(result: Result<TestUser, Error>) {
        self.result = result
    }

    func response<T: Decodable & Sendable>(
        for endpoint: any NetworkEndpoint,
        responseType: T.Type
    ) async throws -> DecodedResponse<T> {
        requestCount += 1
        switch result {
        case .success(let user):
            guard let value = user as? T else {
                throw TestRepositoryError.networkFailure
            }
            return DecodedResponse(value: value)
        case .failure(let error):
            throw error
        }
    }
}
