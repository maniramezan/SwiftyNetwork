import Foundation
import Testing

@testable import SwiftyNetwork

@Test("CacheBasedLocalDataSource reads and writes values")
func testCacheBasedLocalDataSourceReadWrite() async {
    let cache = InMemoryCache<TestUser>()
    let local = CacheBasedLocalDataSource(cache: AnyCache(cache))
    let key = CacheKey("local-key")
    let user = TestUser(id: "1", name: "Sam", email: "sam@example.com")

    await local.write(user, for: key)
    let loaded = await local.read(for: key)

    #expect(loaded == user)
    #expect(await local.timestamp(for: key) != nil)
}

@Test("CacheBasedLocalDataSource removes individual and all values")
func testCacheBasedLocalDataSourceRemove() async {
    let cache = InMemoryCache<TestUser>()
    let local = CacheBasedLocalDataSource(cache: AnyCache(cache))
    let key1 = CacheKey("remove-1")
    let key2 = CacheKey("remove-2")
    let user = TestUser(id: "1", name: "Sam", email: "sam@example.com")

    await local.write(user, for: key1)
    await local.write(user, for: key2)

    await local.remove(for: key1)
    #expect(await local.read(for: key1) == nil)
    #expect(await local.read(for: key2) == user)

    await local.removeAll()
    #expect(await local.read(for: key2) == nil)
}

@Test("GenericRepository returns cached data when available")
func testRepositoryReturnsCachedData() async throws {
    let cache = InMemoryCache<TestUser>()
    let local = CacheBasedLocalDataSource(cache: AnyCache(cache))
    let network = MockNetworkDataSource(result: .success(TestUser(id: "2", name: "Net", email: "net@example.com")))
    let repository = GenericRepository(networkDataSource: network, localDataSource: local)
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
    let local = CacheBasedLocalDataSource(cache: AnyCache(cache))
    let networkUser = TestUser(id: "3", name: "Remote", email: "remote@example.com")
    let network = MockNetworkDataSource(result: .success(networkUser))
    let repository = GenericRepository(networkDataSource: network, localDataSource: local)
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
    let local = CacheBasedLocalDataSource(cache: AnyCache(cache))
    let cached = TestUser(id: "cached", name: "Cache", email: "cache@example.com")
    let networkUser = TestUser(id: "4", name: "Fresh", email: "fresh@example.com")
    await cache.setValue(cached, forKey: CacheKey("reload"))
    let network = MockNetworkDataSource(result: .success(networkUser))
    let repository = GenericRepository(networkDataSource: network, localDataSource: local)
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
    let local = CacheBasedLocalDataSource(cache: AnyCache(cache))
    let user = TestUser(id: "5", name: "FreshCache", email: "freshcache@example.com")
    let key = CacheKey("not-expired")
    let now = Date()
    await cache.setValue(user, forKey: key, timestamp: now)
    let network = MockNetworkDataSource(result: .success(TestUser(id: "net", name: "Net", email: "net@example.com")))
    let repository = GenericRepository(networkDataSource: network, localDataSource: local)

    let fetched = try await repository.fetch(
        using: TestEndpoint(),
        cacheKey: key,
        policy: .returnCacheIfNotExpired(maxAge: 60)
    )

    #expect(fetched == user)
    let count = await network.requestCount
    #expect(count == 0)
}

@Test("GenericRepository refreshes cache when expired")
func testRepositoryRefreshesWhenExpired() async throws {
    let cache = InMemoryCache<TestUser>()
    let local = CacheBasedLocalDataSource(cache: AnyCache(cache))
    let expired = TestUser(id: "expired", name: "Old", email: "old@example.com")
    let key = CacheKey("expired")
    await cache.setValue(expired, forKey: key, timestamp: Date(timeIntervalSince1970: 0))
    let networkUser = TestUser(id: "6", name: "New", email: "new@example.com")
    let network = MockNetworkDataSource(result: .success(networkUser))
    let repository = GenericRepository(networkDataSource: network, localDataSource: local)

    let fetched = try await repository.fetch(
        using: TestEndpoint(),
        cacheKey: key,
        policy: .returnCacheIfNotExpired(maxAge: 1)
    )

    #expect(fetched == networkUser)
    #expect(await cache.value(forKey: key) == networkUser)
    let count = await network.requestCount
    #expect(count == 1)
}

@Test("GenericRepository surfaces network errors")
func testRepositoryPropagatesNetworkError() async {
    let cache = InMemoryCache<TestUser>()
    let local = CacheBasedLocalDataSource(cache: AnyCache(cache))
    let network = MockNetworkDataSource(result: .failure(TestRepositoryError.networkFailure))
    let repository = GenericRepository(networkDataSource: network, localDataSource: local)
    let key = CacheKey("error")

    await #expect {
        try await repository.fetch(using: TestEndpoint(), cacheKey: key, policy: .reloadIgnoringCache)
    } throws: { error in
        error is TestRepositoryError
    }
}

private enum TestRepositoryError: Error {
    case networkFailure
}

private actor MockNetworkDataSource: NetworkDataSource {
    private let result: Result<TestUser, Error>
    private(set) var requestCount = 0

    init(result: Result<TestUser, Error>) {
        self.result = result
    }

    func request<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        responseType: T.Type
    ) async throws -> T {
        requestCount += 1
        switch result {
        case .success(let user):
            guard let value = user as? T else {
                throw TestRepositoryError.networkFailure
            }
            return value
        case .failure(let error):
            throw error
        }
    }
}
