import Foundation
import SwiftyNetworkTesting
import TestCommons
import Testing

@testable import SwiftyNetwork

@Suite("MutationQueue connectivity, responses, and idempotency")
struct MutationQueueConsumerGapTests {
    private let key: MutationKey = "post:create"

    private func makeRequest() -> MutationRequest {
        MutationRequest(baseURL: "https://api.test.com", path: "/posts", method: .post, body: Data("{}".utf8))
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    @Test("Offline failures wait for connectivity without using up retries")
    func offlineDoesNotUseRetries() async {
        let offline = NetworkError.noInternetConnection
        let fake = FakeAPIClient(outcomes: [.failure(offline), .failure(offline), .failure(offline), .success])
        let waits = Counter()
        let queue = MutationQueue(
            client: fake,
            retryPolicy: MutationRetryPolicy(maxRetries: 1, backoff: .immediate),
            waitForConnectivity: { await waits.increment() }
        )
        let stream = await queue.events()

        async let collected = collectEvents(stream, count: 8)
        await queue.enqueue(makeRequest(), key: key)
        let statuses = await collected.map(\.status)

        #expect(
            statuses == [
                .pending,
                .waitingForConnectivity, .pending,
                .waitingForConnectivity, .pending,
                .waitingForConnectivity, .pending,
                .succeeded,
            ]
        )
        #expect(await waits.value == 3)
        #expect(await fake.callCount == 4)
    }

    @Test("A waiting mutation stays in the store until connectivity returns")
    func waitingMutationStaysStored() async throws {
        let fake = FakeAPIClient(outcomes: [.failure(NetworkError.noInternetConnection), .success])
        let store = InMemoryMutationStore()
        let gate = AsyncGate()
        let queue = MutationQueue(
            client: fake,
            store: store,
            retryPolicy: .immediate(),
            waitForConnectivity: { try? await gate.wait() }
        )
        let stream = await queue.events()

        await queue.enqueue(makeRequest(), key: key)
        _ = try await waitUntil(timeout: .seconds(5), operation: { gate.waiterCount }, matching: { $0 == 1 })

        #expect(await queue.status(for: key) == .waitingForConnectivity)
        #expect(await store.load(for: key) == makeRequest())

        gate.open()
        let succeeded = await firstEvent(in: stream) { $0.status == .succeeded }
        #expect(succeeded != nil)
        #expect(await store.load(for: key) == nil)
    }

    @Test("Cancelling a mutation that waits for connectivity reports a cancellation")
    func cancelWhileWaiting() async throws {
        let fake = FakeAPIClient(outcomes: [.failure(NetworkError.noInternetConnection), .success])
        let gate = AsyncGate()
        let queue = MutationQueue(
            client: fake,
            retryPolicy: .immediate(),
            waitForConnectivity: { try? await gate.wait() }
        )

        await queue.enqueue(makeRequest(), key: key)
        _ = try await waitUntil(timeout: .seconds(5), operation: { gate.waiterCount }, matching: { $0 == 1 })
        await queue.cancel(key)
        _ = try await waitUntil(timeout: .seconds(5), operation: { gate.waiterCount }, matching: { $0 == 0 })

        guard case .failed(let reason) = await queue.status(for: key) else {
            Issue.record("Expected a cancellation")
            return
        }
        #expect(reason.isCancellation)
        #expect(await fake.callCount == 1)
    }

    @Test("Without waitForConnectivity, offline failures use up retries as before")
    func offlineWithoutWaitingFails() async {
        let fake = FakeAPIClient(outcomes: [
            .failure(NetworkError.noInternetConnection), .failure(NetworkError.noInternetConnection),
        ])
        let queue = MutationQueue(client: fake, retryPolicy: MutationRetryPolicy(maxRetries: 1, backoff: .immediate))
        let stream = await queue.events()

        await queue.enqueue(makeRequest(), key: key)
        let failed = await firstEvent(in: stream) {
            if case .failed = $0.status { return true }
            return false
        }

        guard case .failed(let reason) = failed?.status else {
            Issue.record("Expected a failure")
            return
        }
        #expect(reason.category == .offline)
    }

    @Test("The succeeded event carries the server's response")
    func succeededEventCarriesResponse() async {
        let client = MockAPIClient()
        let body = Data(#"{"id":"p1"}"#.utf8)
        await client.stub(.post, "/posts", with: .http(HTTPResponse(statusCode: 201, body: body)))
        let queue = MutationQueue(client: client, retryPolicy: .immediate())
        let stream = await queue.events()

        await queue.enqueue(makeRequest(), key: key)
        let succeeded = await firstEvent(in: stream) { $0.status == .succeeded }

        #expect(succeeded?.response?.statusCode == 201)
        #expect(succeeded?.response?.body == body)
    }

    @Test("A plain-text 2xx body does not fail a mutation the server applied")
    func plainTextBodySucceeds() async {
        let client = MockAPIClient()
        await client.stub(.post, "/posts", with: .json(Data("OK".utf8)))
        let queue = MutationQueue(client: client, retryPolicy: .immediate())
        let stream = await queue.events()

        await queue.enqueue(makeRequest(), key: key)
        let terminal = await firstEvent(in: stream) {
            if case .failed = $0.status { return true }
            return $0.status == .succeeded
        }

        #expect(terminal?.status == .succeeded)
    }

    @Test("Every replay sends the same idempotency key")
    func idempotencyKeySurvivesRetries() async {
        let fake = FakeAPIClient(outcomes: [.failure(NetworkError.timeout(nil)), .success])
        let queue = MutationQueue(client: fake, retryPolicy: .immediate())
        let stream = await queue.events()

        await queue.enqueue(makeRequest().addingIdempotencyKey("k-1"), key: key)
        _ = await firstEvent(in: stream) { $0.status == .succeeded }

        let sent = await fake.recordedRequests.map { $0.headers?[MutationRequest.idempotencyKeyHeader] }
        #expect(sent == ["k-1", "k-1"])
    }

    @Test("addingIdempotencyKey keeps an existing key, compared case-insensitively")
    func idempotencyKeyKeepsExisting() {
        var request = makeRequest()
        request.headers = ["idempotency-key": "mine"]

        let keyed = request.addingIdempotencyKey("other")
        let generated = makeRequest().addingIdempotencyKey()

        #expect(keyed.headers == ["idempotency-key": "mine"])
        #expect(generated.headers?[MutationRequest.idempotencyKeyHeader]?.isEmpty == false)
    }

    @Test("MutationRequest keeps an endpoint's provider opt-out through encoding")
    func providerOptOutPersists() throws {
        struct SignIn: NetworkEndpoint {
            let baseURL = "https://api.test.com"
            let path = "/sign-in"
            let method: HTTPMethod = .post
            var usesAuthorizationProvider: Bool { false }
        }
        let request = MutationRequest(endpoint: SignIn())

        let decoded = try JSONDecoder().decode(MutationRequest.self, from: JSONEncoder().encode(request))
        let legacy = try JSONDecoder().decode(
            MutationRequest.self,
            from: Data(#"{"version":1,"baseURL":"https://api.test.com","path":"/a","method":"POST"}"#.utf8)
        )

        #expect(!request.usesAuthorizationProvider)
        #expect(decoded == request)
        #expect(legacy.usesAuthorizationProvider)
    }

    @Test("waitUntilReachable returns when the calling task is cancelled")
    func waitUntilReachableReturnsOnCancellation() async {
        let monitor = NetworkMonitor()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await monitor.waitUntilReachable()
        }
        await task.value
        await monitor.stopMonitoring()
    }
}
