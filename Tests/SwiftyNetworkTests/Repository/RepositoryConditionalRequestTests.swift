import Foundation
import Testing

@testable @_spi(Testing) import SwiftyNetwork

@Suite("GenericRepository conditional requests")
struct RepositoryConditionalRequestTests {
    private let key: CacheKey = "user:123"
    private let ada = TestUser(id: "123", name: "Ada", email: "ada@example.com")
    private let grace = TestUser(id: "123", name: "Grace", email: "grace@example.com")

    private func ok(_ user: TestUser, entityTag: String?) throws -> MockAPIClient.Response {
        let headers = entityTag.map { ["ETag": $0] } ?? [:]
        return .http(HTTPResponse(statusCode: 200, headers: headers, body: try JSONEncoder().encode(user)))
    }

    private func notModified(entityTag: String? = nil) -> MockAPIClient.Response {
        let headers = entityTag.map { ["etag": $0] } ?? [:]
        return .failure(NetworkError.unexpectedStatus(HTTPResponse(statusCode: 304, headers: headers)))
    }

    private func sentTags(_ client: MockAPIClient) async -> [String?] {
        await client.recordedRequests.map { $0.headers?["If-None-Match"] }
    }

    private func reload(
        _ repository: GenericRepository<TestUser>,
        policy: CachePolicy = .reloadElseReturnCache
    ) async throws -> RepositoryResult<TestUser> {
        try await repository.fetchResult(using: TestEndpoint(), cacheKey: key, policy: policy)
    }

    @Test("A 304 keeps the cached entity, reports it as fetched now, and skips observers")
    func notModifiedKeepsCachedEntity() async throws {
        let client = MockAPIClient()
        await client.stub(.get, "/users/123", with: try ok(ada, entityTag: "\"v1\""), notModified())
        let cache = InMemoryCache<TestUser>()
        let repository = GenericRepository(client: client, cache: cache, validators: InMemoryCache<String>())

        let first = try await reload(repository)
        let written = Date(timeIntervalSince1970: 1_000)
        await cache.setEntry(CacheEntry(ada, timestamp: written), forKey: key)
        let second = try await reload(repository)

        #expect(first.value == ada)
        #expect(second.value == ada)
        #expect(second.source == .network)
        #expect(second.timestamp > written)
        #expect(await cache.entry(forKey: key)?.timestamp == second.timestamp)
        #expect(await sentTags(client) == [nil, "\"v1\""])
    }

    @Test("A changed entity replaces the cached one and its tag")
    func modifiedEntityReplacesValueAndTag() async throws {
        let client = MockAPIClient()
        await client.stub(
            .get, "/users/123",
            with: try ok(ada, entityTag: "\"v1\""), try ok(grace, entityTag: "\"v2\""), notModified())
        let repository = GenericRepository(
            client: client, cache: InMemoryCache<TestUser>(), validators: InMemoryCache<String>())

        _ = try await reload(repository)
        let second = try await reload(repository)
        let third = try await reload(repository)

        #expect(second.value == grace)
        #expect(third.value == grace)
        #expect(await sentTags(client) == [nil, "\"v1\"", "\"v2\""])
    }

    @Test("A 304 that carries a new tag updates the stored tag")
    func notModifiedCanRotateTheTag() async throws {
        let client = MockAPIClient()
        await client.stub(
            .get, "/users/123",
            with: try ok(ada, entityTag: "\"v1\""), notModified(entityTag: "\"v2\""), notModified())
        let repository = GenericRepository(
            client: client, cache: InMemoryCache<TestUser>(), validators: InMemoryCache<String>())

        _ = try await reload(repository)
        _ = try await reload(repository)
        _ = try await reload(repository)

        #expect(await sentTags(client) == [nil, "\"v1\"", "\"v2\""])
    }

    @Test("Without validators, requests are never conditional")
    func plainRepositorySendsNoCondition() async throws {
        let client = MockAPIClient()
        await client.stub(.get, "/users/123", with: try ok(ada, entityTag: "\"v1\""))
        let repository = GenericRepository(client: client, cache: InMemoryCache<TestUser>())

        _ = try await reload(repository)
        _ = try await reload(repository)

        #expect(await sentTags(client) == [nil, nil])
    }

    @Test("reloadIgnoringCache sends no condition but still records the new tag")
    func reloadIgnoringCacheIsUnconditional() async throws {
        let client = MockAPIClient()
        await client.stub(
            .get, "/users/123",
            with: try ok(ada, entityTag: "\"v1\""), try ok(grace, entityTag: "\"v2\""), notModified())
        let repository = GenericRepository(
            client: client, cache: InMemoryCache<TestUser>(), validators: InMemoryCache<String>())

        _ = try await reload(repository)
        let forced = try await reload(repository, policy: .reloadIgnoringCache)
        _ = try await reload(repository)

        #expect(forced.value == grace)
        #expect(await sentTags(client) == [nil, nil, "\"v2\""])
    }

    @Test("A tag whose entity left the cache is not sent")
    func evictedEntityIsFetchedInFull() async throws {
        let client = MockAPIClient()
        await client.stub(.get, "/users/123", with: try ok(ada, entityTag: "\"v1\""))
        let cache = InMemoryCache<TestUser>()
        let repository = GenericRepository(client: client, cache: cache, validators: InMemoryCache<String>())

        _ = try await reload(repository)
        await cache.removeValue(forKey: key)
        let second = try await reload(repository)

        #expect(second.value == ada)
        #expect(await sentTags(client) == [nil, nil])
    }

    @Test("Writing or removing an entity through the repository drops its tag", arguments: [true, false])
    func localChangesDropTheTag(write: Bool) async throws {
        let client = MockAPIClient()
        await client.stub(.get, "/users/123", with: try ok(ada, entityTag: "\"v1\""))
        let repository = GenericRepository(
            client: client, cache: InMemoryCache<TestUser>(), validators: InMemoryCache<String>())

        _ = try await reload(repository)
        if write {
            await repository.setCachedValue(grace, forKey: key)
        } else {
            await repository.removeCachedValue(forKey: key)
        }
        _ = try await reload(repository)

        #expect(await sentTags(client) == [nil, nil])
    }

    @Test("A response without a tag clears the stored one")
    func missingTagClearsValidator() async throws {
        let client = MockAPIClient()
        await client.stub(
            .get, "/users/123",
            with: try ok(ada, entityTag: "\"v1\""), try ok(grace, entityTag: nil), try ok(grace, entityTag: nil))
        let repository = GenericRepository(
            client: client, cache: InMemoryCache<TestUser>(), validators: InMemoryCache<String>())

        _ = try await reload(repository)
        _ = try await reload(repository)
        _ = try await reload(repository)

        #expect(await sentTags(client) == [nil, "\"v1\"", nil])
    }

    @Test("An unexpected 304 to a plain request is thrown")
    func unsolicitedNotModifiedIsAnError() async throws {
        let client = MockAPIClient()
        await client.stub(.get, "/users/123", with: notModified())
        let repository = GenericRepository(
            client: client, cache: InMemoryCache<TestUser>(), validators: InMemoryCache<String>())

        await #expect(throws: NetworkError.self) {
            try await repository.fetchResult(using: TestEndpoint(), cacheKey: key, policy: .reloadIgnoringCache)
        }
    }

    @Test("The condition replaces an If-None-Match the endpoint declares and keeps its other headers")
    func conditionalEndpointMergesHeaders() {
        struct Tagged: NetworkEndpoint {
            let baseURL = "https://api.test.com"
            let path = "/users/123"
            let method: HTTPMethod = .get
            var headers: [String: String]? { ["if-none-match": "\"old\"", "Accept": "application/json"] }
            var usesAuthorizationProvider: Bool { false }
        }
        let endpoint = ConditionalEndpoint(wrapped: Tagged(), entityTag: "\"v1\"")

        #expect(endpoint.headers == ["If-None-Match": "\"v1\"", "Accept": "application/json"])
        #expect(!endpoint.usesAuthorizationProvider)
    }

    @Test("NetworkClient reports a 304 in the form the repository handles")
    func networkClientNotModified() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let client = NetworkClient(configuration: NetworkClientConfiguration(session: stub.session))
        stub.setResponses([.status(304)], for: "conditional-304")
        let cache = InMemoryCache<TestUser>()
        let validators = InMemoryCache<String>()
        await cache.setValue(ada, forKey: key)
        await validators.setValue("\"v1\"", forKey: key)
        let repository = GenericRepository(client: client, cache: cache, validators: validators)

        let result = try await repository.fetchResult(
            using: makeEndpointWithTestId("conditional-304"), cacheKey: key, policy: .reloadElseReturnCache)

        #expect(result.value == ada)
        #expect(result.source == .network)
    }
}
