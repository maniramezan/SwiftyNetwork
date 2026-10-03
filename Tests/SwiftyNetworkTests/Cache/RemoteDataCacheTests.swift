import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("RemoteDataCache Tests")
struct RemoteDataCacheTests {

    private func makeURL(testId: String) -> URL {
        URL(string: "https://api.test.com/image.png?test-id=\(testId)")!
    }

    @Test("Fetches from the network on a miss and caches the result")
    func fetchesAndCaches() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "fetch-and-cache"
        let url = makeURL(testId: testId)
        let expected = Data([0xDE, 0xAD, 0xBE, 0xEF])
        stub.setResponses([.success(expected)], for: testId)

        let cache = RemoteDataCache(cache: InMemoryCache<Data>(), session: stub.session)

        let first = try await cache.data(for: url)
        #expect(first == expected)

        // Only one response was queued; a second network call would fail
        // with a dequeue error, so a successful second call proves it was
        // served from cache rather than hitting the network again.
        let second = try await cache.data(for: url)
        #expect(second == expected)
        #expect(await cache.cachedData(for: url) == expected)
    }

    @Test("Concurrent requests for the same URL coalesce into a single fetch")
    func concurrentRequestsCoalesce() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "coalesce"
        let url = makeURL(testId: testId)
        let expected = Data([1, 2, 3])
        // One scripted response makes a duplicate network fetch fail.
        stub.setResponses([.success(expected)], for: testId)

        let cache = RemoteDataCache(cache: InMemoryCache<Data>(), session: stub.session)

        async let first = cache.data(for: url)
        async let second = cache.data(for: url)
        let (firstResult, secondResult) = try await (first, second)

        #expect(firstResult == expected)
        #expect(secondResult == expected)
        #expect(stub.requests.count == 1)
    }

    @Test("Maps a non-2xx HTTP status to NetworkError.serverError")
    func mapsServerError() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "server-error"
        let url = makeURL(testId: testId)
        stub.setResponses([.status(500)], for: testId)

        let cache = RemoteDataCache(cache: InMemoryCache<Data>(), session: stub.session)

        await #expect(throws: NetworkError.self) {
            try await cache.data(for: url)
        }
        #expect(await cache.cachedData(for: url) == nil)
    }

    @Test("Maps 4xx statuses the same way NetworkClient does")
    func mapsClientErrorsLikeNetworkClient() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let cases: [(status: Int, expected: NetworkErrorClassification)] = [
            (401, .unauthorized),
            (403, .forbidden),
            (404, .notFound),
            (408, .timeout),
            (429, .serverError(statusCode: 429)),
        ]
        let cache = RemoteDataCache(cache: InMemoryCache<Data>(), session: stub.session)

        for (status, expected) in cases {
            let testId = "status-mapping-\(status)"
            stub.setResponses([.status(status)], for: testId)
            do {
                _ = try await cache.data(for: makeURL(testId: testId))
                Issue.record("Expected status \(status) to throw")
            } catch let error as NetworkError {
                #expect(error.classification == expected, "status \(status)")
            } catch {
                Issue.record("Unexpected error for status \(status): \(error)")
            }
        }
    }

    @Test("Maps a transport failure to the corresponding NetworkError classification")
    func mapsTransportFailure() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "transport-failure"
        let url = makeURL(testId: testId)
        stub.setResponses([.failure(URLError(.notConnectedToInternet))], for: testId)

        let cache = RemoteDataCache(cache: InMemoryCache<Data>(), session: stub.session)

        do {
            _ = try await cache.data(for: url)
            Issue.record("Expected data(for:) to throw")
        } catch let error as NetworkError {
            #expect(error.classification == .noConnection)
        } catch {
            Issue.record("Expected a NetworkError, got \(error)")
        }
    }

    @Test("removeValue evicts a cached entry so the next call fetches again")
    func removeValueEvicts() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "remove-value"
        let url = makeURL(testId: testId)
        let first = Data([1])
        let second = Data([2])
        stub.setResponses([.success(first)], for: testId)

        let cache = RemoteDataCache(cache: InMemoryCache<Data>(), session: stub.session)
        #expect(try await cache.data(for: url) == first)

        await cache.removeValue(for: url)
        #expect(await cache.cachedData(for: url) == nil)

        stub.setResponses([.success(second)], for: testId)
        #expect(try await cache.data(for: url) == second)
    }

    @Test("removeAll clears every cached entry")
    func removeAllClears() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let idA = "remove-all-a"
        let idB = "remove-all-b"
        let urlA = makeURL(testId: idA)
        let urlB = makeURL(testId: idB)
        stub.setResponses([.success(Data([1]))], for: idA)
        stub.setResponses([.success(Data([2]))], for: idB)

        let cache = RemoteDataCache(cache: InMemoryCache<Data>(), session: stub.session)
        _ = try await cache.data(for: urlA)
        _ = try await cache.data(for: urlB)

        await cache.removeAll()

        #expect(await cache.cachedData(for: urlA) == nil)
        #expect(await cache.cachedData(for: urlB) == nil)
    }

    @Test("Composes with LayeredCache for app-supplied memory + disk layering")
    func composesWithLayeredCache() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let testId = "layered"
        let url = makeURL(testId: testId)
        let expected = Data([9, 9, 9])
        stub.setResponses([.success(expected)], for: testId)

        let memory = InMemoryCache<Data>(maxSize: 50)
        let disk = TestDiskDataCache()
        let layered = LayeredCache(memoryCache: memory, persistentCache: disk)
        let cache = RemoteDataCache(cache: layered, session: stub.session)

        let result = try await cache.data(for: url)

        #expect(result == expected)
        #expect(await disk.value(forKey: CacheKey(url: url)) == expected)
    }
}

/// A minimal `PersistentCache` used to prove `RemoteDataCache` composes with
/// any app-supplied disk layer via `LayeredCache`, rather than being tied to
/// a specific storage mechanism.
private actor TestDiskDataCache: PersistentCache {
    typealias Value = Data
    private var storage: [CacheKey: (Data, Date)] = [:]

    func value(forKey key: CacheKey) async -> Data? { storage[key]?.0 }
    func setValue(_ value: Data, forKey key: CacheKey) async { storage[key] = (value, Date()) }
    func removeValue(forKey key: CacheKey) async { storage.removeValue(forKey: key) }
    func removeAll() async { storage.removeAll() }
    func timestamp(forKey key: CacheKey) async -> Date? { storage[key]?.1 }
}
