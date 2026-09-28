import Foundation
import SwiftyNetworkTesting
import Testing

@testable import SwiftyNetwork

@Suite("MockAPIClient Tests")
struct MockAPIClientTests {
    private struct UserEndpoint: NetworkEndpoint {
        let baseURL = "https://api.example.com"
        let path = "/users/1"
        let method: HTTPMethod = .get
    }

    private struct LikeEndpoint: NetworkEndpoint {
        let baseURL = "https://api.example.com"
        let path = "/likes"
        let method: HTTPMethod = .post
    }

    @Test("Returns a stubbed Encodable value through JSON decoding")
    func returnsStubbedValue() async throws {
        let client = MockAPIClient()
        let user = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        try await client.stub(.get, "/users/1", returning: user)

        let received = try await client.request(UserEndpoint(), responseType: TestUser.self)

        #expect(received == user)
        #expect(await client.requests(to: "/users/1").count == 1)
    }

    @Test("Consumes queued responses in order and repeats the last one")
    func consumesQueuedResponsesInOrder() async throws {
        let client = MockAPIClient()
        await client.stub(.post, "/likes", with: .failure(NetworkError.timeout), .empty)

        await #expect(throws: NetworkError.self) {
            try await client.request(LikeEndpoint())
        }
        try await client.request(LikeEndpoint())
        try await client.request(LikeEndpoint())

        #expect(await client.recordedRequests.count == 3)
    }

    @Test("Throws UnstubbedRequestError for unknown routes unless a fallback is set")
    func unstubbedRoutes() async throws {
        let client = MockAPIClient()

        await #expect(throws: MockAPIClient.UnstubbedRequestError.self) {
            try await client.request(LikeEndpoint())
        }

        await client.setFallback(.empty)
        try await client.request(LikeEndpoint())
    }

    @Test("Value stubs of the wrong type throw TypeMismatchError")
    func valueTypeMismatch() async {
        let client = MockAPIClient()
        await client.stub(.get, "/users/1", with: .value("not a user"))

        await #expect(throws: MockAPIClient.TypeMismatchError.self) {
            try await client.request(UserEndpoint(), responseType: TestUser.self)
        }
    }

    @Test("Undecodable JSON surfaces as NetworkError.decodingFailed")
    func decodingFailure() async {
        let client = MockAPIClient()
        await client.stub(.get, "/users/1", with: .json(Data("{}".utf8)))

        do {
            _ = try await client.request(UserEndpoint(), responseType: TestUser.self)
            Issue.record("Expected a decoding failure")
        } catch let error as NetworkError {
            #expect(error.classification == .decodingFailed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Drives GenericRepository without URLSession")
    func drivesRepository() async throws {
        let client = MockAPIClient()
        let user = TestUser(id: "1", name: "Ada", email: "ada@example.com")
        try await client.stub(.get, "/users/1", returning: user)
        let repository = GenericRepository<TestUser>(
            networkDataSource: client,
            localDataSource: CacheBasedLocalDataSource(cache: InMemoryCache<TestUser>())
        )

        let key = CacheKey("user:1")
        _ = try await repository.fetch(using: UserEndpoint(), cacheKey: key, policy: .returnCacheElseLoad)
        let cached = try await repository.fetch(using: UserEndpoint(), cacheKey: key, policy: .returnCacheElseLoad)

        #expect(cached == user)
        #expect(await client.recordedRequests.count == 1)
    }

    @Test("Records encoded bodies for assertions")
    func recordsBodies() async throws {
        let client = MockAPIClient()
        await client.stub(.post, "/likes", with: .empty)
        let request = try MutationRequest(endpoint: LikeEndpoint(), encodableBody: ["videoID": "42"])

        try await client.request(request)

        let recorded = try #require(await client.recordedRequests.first)
        #expect(try recorded.decodedBody(as: [String: String].self) == ["videoID": "42"])
        #expect(recorded.headers?["Content-Type"] == "application/json")
    }

    @Test("MutationQueue retries through the mock with an immediate policy")
    func mutationQueueWithImmediatePolicy() async {
        let client = MockAPIClient()
        await client.stub(.post, "/likes", with: .failure(NetworkError.timeout), .empty)
        let queue = MutationQueue(client: client, retryPolicy: .immediate())
        let events = await queue.events()

        await queue.enqueue(MutationRequest(endpoint: LikeEndpoint()), key: "like:42")

        let succeeded = await firstEvent(in: events) { $0.status == .succeeded }
        #expect(succeeded?.key == "like:42")
        #expect(await client.recordedRequests.count == 2)
    }
}
