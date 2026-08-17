import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("MutationQueue Tests")
struct MutationQueueTests {

    private func makeRequest(path: String = "/videos/42/like", liked: Bool = true) -> MutationRequest {
        MutationRequest(
            baseURL: "https://api.test.com",
            path: path,
            method: .post,
            body: Data("{\"liked\":\(liked)}".utf8)
        )
    }

    private static let noDelayPolicy = MutationRetryPolicy(
        maxAttempts: 5,
        baseDelay: 0,
        maxDelay: 0,
        jitterRange: 0...0
    )

    @Test("A successful mutation reports pending then succeeded, and is removed from the store")
    func succeedsOnFirstAttempt() async {
        let fake = FakeAPIClient(outcomes: [.success])
        let store = InMemoryMutationStore()
        let queue = MutationQueue(client: fake, store: store, retryPolicy: Self.noDelayPolicy)
        let stream = await queue.events()

        async let collected = collectEvents(stream, count: 2)
        await queue.enqueue(makeRequest(), key: "like:video:42")
        let events = await collected

        #expect(events.map(\.status) == [.pending, .succeeded])
        #expect(await fake.callCount == 1)
        #expect(await queue.status(for: "like:video:42") == .succeeded)
        #expect(await store.load(for: "like:video:42") == nil)
    }

    @Test("Transient failures are retried in the background until success")
    func retriesTransientFailuresThenSucceeds() async {
        let fake = FakeAPIClient(outcomes: [.failure(NetworkError.timeout), .failure(NetworkError.timeout), .success])
        let queue = MutationQueue(client: fake, store: InMemoryMutationStore(), retryPolicy: Self.noDelayPolicy)
        let stream = await queue.events()

        async let collected = collectEvents(stream, count: 4)
        await queue.enqueue(makeRequest(), key: "like:video:42")
        let events = await collected

        #expect(events.map(\.status) == [.pending, .retrying(attempt: 1), .retrying(attempt: 2), .succeeded])
        #expect(await fake.callCount == 3)
    }

    @Test("Retries are exhausted and the mutation is reported failed")
    func exhaustsRetriesAndFails() async {
        let policy = MutationRetryPolicy(maxAttempts: 2, baseDelay: 0, maxDelay: 0, jitterRange: 0...0)
        let fake = FakeAPIClient(
            outcomes: [.failure(NetworkError.timeout), .failure(NetworkError.timeout), .failure(NetworkError.timeout)]
        )
        let store = InMemoryMutationStore()
        let queue = MutationQueue(client: fake, store: store, retryPolicy: policy)
        let stream = await queue.events()

        async let collected = collectEvents(stream, count: 4)
        await queue.enqueue(makeRequest(), key: "like:video:42")
        let events = await collected

        #expect(
            events.map(\.status) == [
                .pending, .retrying(attempt: 1), .retrying(attempt: 2),
                .failed(MutationFailureReason(NetworkError.timeout)),
            ])
        #expect(await fake.callCount == 3)
        #expect(await store.load(for: "like:video:42") == nil)
    }

    @Test("Non-retryable failures are reported failed without retrying")
    func nonRetryableFailureFailsImmediately() async {
        let fake = FakeAPIClient(outcomes: [.failure(NetworkError.forbidden)])
        let queue = MutationQueue(client: fake, store: InMemoryMutationStore(), retryPolicy: Self.noDelayPolicy)
        let stream = await queue.events()

        async let collected = collectEvents(stream, count: 2)
        await queue.enqueue(makeRequest(), key: "like:video:42")
        let events = await collected

        #expect(events.map(\.status) == [.pending, .failed(MutationFailureReason(NetworkError.forbidden))])
        #expect(await fake.callCount == 1)
    }

    @Test("Re-enqueueing before the in-flight call finishes coalesces to the latest desired state")
    func coalescesReenqueueDuringInFlightCall() async {
        let gate = Gate()
        let fake = FakeAPIClient(outcomes: [.success, .success], gate: gate)
        let store = InMemoryMutationStore()
        let queue = MutationQueue(client: fake, store: store, retryPolicy: Self.noDelayPolicy)
        let stream = await queue.events()

        let liked = makeRequest(liked: true)
        let unliked = makeRequest(liked: false)

        async let finalEvent = firstEvent(in: stream) { event in
            event.key == "like:video:42" && event.status == .succeeded
        }

        await queue.enqueue(liked, key: "like:video:42")
        // Wait for the first call to actually start (and block on the gate)
        // before superseding it, so the coalescing branch is deterministic
        // rather than racing a fixed delay.
        while await fake.callCount == 0 { await Task.yield() }
        await queue.enqueue(unliked, key: "like:video:42")
        await gate.open()
        let succeeded = await finalEvent

        #expect(succeeded != nil)
        // The in-flight call for "liked" isn't cancelled, but its result is
        // discarded in favor of processing "unliked" next -- never replaying
        // every intermediate state.
        #expect(await fake.callCount == 2)
        #expect(await fake.recordedRequests.map(\.body) == [liked.body, unliked.body])
        #expect(await store.load(for: "like:video:42") == nil)
    }

    @Test("Rapid re-enqueueing before the first call even starts sends only the final state")
    func coalescesReenqueueBeforeProcessingStarts() async {
        let fake = FakeAPIClient(outcomes: [.success])
        let store = InMemoryMutationStore()
        let queue = MutationQueue(client: fake, store: store, retryPolicy: Self.noDelayPolicy)
        let stream = await queue.events()

        let liked = makeRequest(liked: true)
        let unliked = makeRequest(liked: false)

        async let finalEvent = firstEvent(in: stream) { event in
            event.key == "like:video:42" && event.status == .succeeded
        }

        await queue.enqueue(liked, key: "like:video:42")
        await queue.enqueue(unliked, key: "like:video:42")
        let succeeded = await finalEvent

        #expect(succeeded != nil)
        // Whether the processing task happened to observe "liked" before it
        // was superseded is a scheduling detail; either way the last call
        // actually sent to the server must be the final desired state.
        let callCount = await fake.callCount
        #expect(callCount == 1 || callCount == 2)
        #expect(await fake.recordedRequests.last?.body == unliked.body)
    }

    @Test("A non-retryable failure does not discard a replacement enqueued while it was in flight")
    func nonRetryableFailurePreservesInFlightReplacement() async {
        let gate = Gate()
        let fake = FakeAPIClient(outcomes: [.failure(NetworkError.forbidden), .success], gate: gate)
        let store = InMemoryMutationStore()
        let queue = MutationQueue(client: fake, store: store, retryPolicy: Self.noDelayPolicy)
        let stream = await queue.events()

        let liked = makeRequest(liked: true)
        let unliked = makeRequest(liked: false)

        async let finalEvent = firstEvent(in: stream) { event in
            guard event.key == "like:video:42" else { return false }
            switch event.status {
            case .succeeded, .failed: return true
            case .pending, .retrying: return false
            }
        }

        await queue.enqueue(liked, key: "like:video:42")
        while await fake.callCount == 0 { await Task.yield() }
        await queue.enqueue(unliked, key: "like:video:42")
        await gate.open()
        let terminalEvent = await finalEvent

        // The old (now-superseded) call fails permanently, but "unliked" was
        // already saved as the new desired state -- it must still be
        // processed and reported, not silently dropped alongside the failure.
        #expect(terminalEvent?.status == .succeeded)
        #expect(await fake.callCount == 2)
        #expect(await fake.recordedRequests.map(\.body) == [liked.body, unliked.body])
        #expect(await store.load(for: "like:video:42") == nil)
    }

    @Test("Exhausted retries do not discard a replacement enqueued while the terminal attempt is in flight")
    func exhaustedRetriesPreserveReplacement() async {
        // Only the terminal (second, index 1) attempt is gated: the first
        // attempt fails and schedules a retry, then the retry blocks so the
        // test can supersede the key while that terminal attempt is in flight.
        let terminalAttemptGate = Gate()
        let policy = MutationRetryPolicy(maxAttempts: 1, baseDelay: 0, maxDelay: 0, jitterRange: 0...0)
        let fake = FakeAPIClient(
            outcomes: [.failure(NetworkError.timeout), .failure(NetworkError.timeout), .success],
            gatesByCallIndex: [1: terminalAttemptGate]
        )
        let store = InMemoryMutationStore()
        let queue = MutationQueue(client: fake, store: store, retryPolicy: policy)
        let stream = await queue.events()

        let liked = makeRequest(liked: true)
        let unliked = makeRequest(liked: false)

        async let finalEvent = firstEvent(in: stream) { event in
            event.key == "like:video:42" && event.status == .succeeded
        }

        await queue.enqueue(liked, key: "like:video:42")
        while await fake.callCount < 2 { await Task.yield() }
        await queue.enqueue(unliked, key: "like:video:42")
        await terminalAttemptGate.open()
        let succeeded = await finalEvent

        #expect(succeeded != nil)
        #expect(await fake.callCount == 3)
        #expect(await fake.recordedRequests.last?.body == unliked.body)
        #expect(await store.load(for: "like:video:42") == nil)
    }

    @Test("resumePendingMutations processes mutations already in a durable store")
    func resumePendingMutationsProcessesExistingEntries() async {
        let fake = FakeAPIClient(outcomes: [.success])
        let store = InMemoryMutationStore()
        // Simulate a durable store that already had a mutation saved from a
        // previous process, before any MutationQueue observed it.
        await store.save(makeRequest(), for: "like:video:42")
        let queue = MutationQueue(client: fake, store: store, retryPolicy: Self.noDelayPolicy)
        let stream = await queue.events()

        async let finalEvent = firstEvent(in: stream) { $0.key == "like:video:42" && $0.status == .succeeded }
        await queue.resumePendingMutations()
        let succeeded = await finalEvent

        #expect(succeeded != nil)
        #expect(await fake.callCount == 1)
        #expect(await store.load(for: "like:video:42") == nil)
    }

    @Test("resumePendingMutations is a no-op when the store is empty")
    func resumePendingMutationsNoOpWhenEmpty() async {
        let fake = FakeAPIClient(outcomes: [])
        let queue = MutationQueue(client: fake, store: InMemoryMutationStore(), retryPolicy: Self.noDelayPolicy)

        await queue.resumePendingMutations()

        #expect(await fake.callCount == 0)
    }

    @Test("A positive retry delay is actually awaited before the next attempt")
    func retryDelayIsAwaited() async {
        let policy = MutationRetryPolicy(maxAttempts: 3, baseDelay: 0.01, maxDelay: 0.01, jitterRange: 1...1)
        let fake = FakeAPIClient(outcomes: [.failure(NetworkError.timeout), .success])
        let queue = MutationQueue(client: fake, store: InMemoryMutationStore(), retryPolicy: policy)
        let stream = await queue.events()

        async let collected = collectEvents(stream, count: 3)
        let start = Date()
        await queue.enqueue(makeRequest(), key: "like:video:42")
        let events = await collected
        let elapsed = Date().timeIntervalSince(start)

        #expect(events.map(\.status) == [.pending, .retrying(attempt: 1), .succeeded])
        #expect(elapsed >= 0.01)
    }

    @Test("Independent keys are processed without blocking each other")
    func independentKeysProcessConcurrently() async {
        let slowFake = FakeAPIClient(
            outcomes: [.failure(NetworkError.timeout), .failure(NetworkError.timeout), .success],
            delayNanoseconds: 20_000_000
        )
        let fastFake = FakeAPIClient(outcomes: [.success])

        // A single queue can only hold one client, so exercise both keys
        // against a router that dispatches by path.
        let router = RoutingAPIClient(slow: slowFake, fast: fastFake)
        let queue = MutationQueue(client: router, store: InMemoryMutationStore(), retryPolicy: Self.noDelayPolicy)
        let stream = await queue.events()

        async let fastSucceeded = firstEvent(in: stream) { $0.key == "fast" && $0.status == .succeeded }

        await queue.enqueue(makeRequest(path: "/slow"), key: "slow")
        await queue.enqueue(makeRequest(path: "/fast"), key: "fast")

        let fastEvent = await fastSucceeded
        #expect(fastEvent != nil)
        // The fast key finished even though the slow key is still retrying.
        let slowStatus = await queue.status(for: "slow")
        #expect(slowStatus != .succeeded)
    }

    @Test("Debug-level logging exercises every log call site without changing behavior")
    func loggingAtDebugLevelDoesNotAffectOutcomes() async {
        // Matches the existing convention (see NetworkClientTests) of setting
        // the package-wide log level to .debug without resetting it -- the
        // level is process-global, and no test asserts on log output.
        Logger.setLevel(.debug)

        // Exercise resumePendingMutations (.info), a transient-then-success
        // retry (.debug + .warning + .debug), and a permanent failure (.error).
        let store = InMemoryMutationStore()
        await store.save(makeRequest(liked: true), for: "resume:1")
        let fake = FakeAPIClient(outcomes: [.failure(NetworkError.timeout), .success, .failure(NetworkError.forbidden)])
        let queue = MutationQueue(client: fake, store: store, retryPolicy: Self.noDelayPolicy)
        let stream = await queue.events()

        async let resumeSucceeded = firstEvent(in: stream) { $0.key == "resume:1" && $0.status == .succeeded }
        await queue.resumePendingMutations()
        #expect(await resumeSucceeded != nil)

        async let permanentlyFailed = firstEvent(in: stream) { $0.key == "other:1" && $0.status != .pending }
        await queue.enqueue(makeRequest(path: "/other"), key: "other:1")
        let failedEvent = await permanentlyFailed

        #expect(failedEvent?.status == .failed(MutationFailureReason(NetworkError.forbidden)))
    }

    @Test("status(for:) returns nil for a key that was never enqueued")
    func statusForUnknownKeyIsNil() async {
        let queue = MutationQueue(client: FakeAPIClient(outcomes: []), store: InMemoryMutationStore())

        #expect(await queue.status(for: "unknown") == nil)
    }
}

/// Dispatches to one of two fakes by endpoint path, used to prove two
/// mutation keys process concurrently rather than serially.
private actor RoutingAPIClient: APIClient {
    let slow: FakeAPIClient
    let fast: FakeAPIClient

    init(slow: FakeAPIClient, fast: FakeAPIClient) {
        self.slow = slow
        self.fast = fast
    }

    func request<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        responseType: T.Type
    ) async throws -> T {
        if endpoint.path == "/fast" {
            return try await fast.request(endpoint, responseType: responseType)
        }
        return try await slow.request(endpoint, responseType: responseType)
    }
}
