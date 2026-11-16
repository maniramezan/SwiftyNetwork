import Foundation
import TestCommons
import Testing

@testable @_spi(Testing) import SwiftyNetwork

@Suite("MutationQueue concurrency limit")
struct MutationQueueConcurrencyLimitTests {
    private func makeRequest(_ path: String) -> MutationRequest {
        MutationRequest(baseURL: "https://api.test.com", path: path, method: .post)
    }

    private func waitUntilIdle(_ queue: MutationQueue) async throws {
        _ = try await waitUntil(
            timeout: testTimeout, operation: { await queue.pendingKeys() }, matching: { $0.isEmpty })
    }

    private func waitForCalls(_ count: Int, on fake: FakeAPIClient) async throws {
        _ = try await waitUntil(timeout: testTimeout, operation: { await fake.callCount }, matching: { $0 == count })
    }

    private func waitForQueuedAttempts(_ count: Int, on queue: MutationQueue) async throws {
        _ = try await waitUntil(
            timeout: testTimeout, operation: { await queue.queuedAttemptCount }, matching: { $0 == count })
    }

    @Test("Mutations over the limit wait and are sent in the order they became ready")
    func sendsOneAtATimeInOrder() async throws {
        let fake = FakeAPIClient(outcomes: [])
        let gate = await fake.hold(call: 0)
        defer { gate.open() }
        let queue = MutationQueue(client: fake, retryPolicy: .immediate(), maxConcurrentMutations: 1)

        await queue.enqueue(makeRequest("/a"), key: "a")
        try await waitForCalls(1, on: fake)
        // Each worker joins the slot queue on its own task, so wait for one before enqueueing the next.
        await queue.enqueue(makeRequest("/b"), key: "b")
        try await waitForQueuedAttempts(1, on: queue)
        await queue.enqueue(makeRequest("/c"), key: "c")
        try await waitForQueuedAttempts(2, on: queue)

        #expect(await fake.callCount == 1)
        #expect(await queue.pendingKeys() == ["a", "b", "c"])
        #expect(await queue.status(for: "b") == .pending)

        gate.open()
        try await waitUntilIdle(queue)

        #expect(await fake.recordedRequests.map(\.path) == ["/a", "/b", "/c"])
        #expect(await queue.status(for: "c") == .succeeded)
    }

    @Test("A mutation replaced while it waits for a slot is never sent")
    func replacedWhileWaitingSendsOnlyTheLatest() async throws {
        let fake = FakeAPIClient(outcomes: [])
        let gate = await fake.hold(call: 0)
        defer { gate.open() }
        let queue = MutationQueue(client: fake, retryPolicy: .immediate(), maxConcurrentMutations: 1)

        await queue.enqueue(makeRequest("/a"), key: "a")
        try await waitForCalls(1, on: fake)
        await queue.enqueue(makeRequest("/old"), key: "b")
        await queue.enqueue(makeRequest("/new"), key: "b")
        gate.open()
        try await waitUntilIdle(queue)

        #expect(await fake.recordedRequests.map(\.path) == ["/a", "/new"])
    }

    @Test("Cancelling a waiting mutation does not hold back the ones behind it")
    func cancelledWaiterGivesItsSlotBack() async throws {
        let fake = FakeAPIClient(outcomes: [])
        let gate = await fake.hold(call: 0)
        defer { gate.open() }
        let queue = MutationQueue(client: fake, retryPolicy: .immediate(), maxConcurrentMutations: 1)

        await queue.enqueue(makeRequest("/a"), key: "a")
        try await waitForCalls(1, on: fake)
        await queue.enqueue(makeRequest("/b"), key: "b")
        await queue.enqueue(makeRequest("/c"), key: "c")
        await queue.cancel("b")
        gate.open()
        try await waitUntilIdle(queue)

        #expect(await fake.recordedRequests.map(\.path) == ["/a", "/c"])
        #expect(await queue.status(for: "c") == .succeeded)
    }

    @Test("A retry gives up its slot while it backs off")
    func retryReleasesItsSlot() async throws {
        let fake = FakeAPIClient(outcomes: [.failure(NetworkError.timeout(nil)), .success, .success])
        let queue = MutationQueue(client: fake, retryPolicy: .immediate(), maxConcurrentMutations: 1)

        await queue.enqueue(makeRequest("/a"), key: "a")
        await queue.enqueue(makeRequest("/b"), key: "b")
        try await waitUntilIdle(queue)

        #expect(await fake.callCount == 3)
        #expect(await queue.status(for: "a") == .succeeded)
        #expect(await queue.status(for: "b") == .succeeded)
    }

    @Test("A limit below one still sends mutations")
    func clampsTheLimitToOne() async throws {
        let fake = FakeAPIClient(outcomes: [])
        let queue = MutationQueue(client: fake, retryPolicy: .immediate(), maxConcurrentMutations: 0)

        await queue.enqueue(makeRequest("/a"), key: "a")
        try await waitUntilIdle(queue)

        #expect(await fake.callCount == 1)
    }

    @Test("pendingKeys lists unfinished mutations and empties when they finish")
    func pendingKeysTracksUnfinishedMutations() async throws {
        let fake = FakeAPIClient(outcomes: [])
        let gate = await fake.hold(call: 0)
        defer { gate.open() }
        let queue = MutationQueue(client: fake, retryPolicy: .immediate())

        #expect(await queue.pendingKeys().isEmpty)
        await queue.enqueue(makeRequest("/a"), key: "a")
        #expect(await queue.pendingKeys() == ["a"])
        gate.open()
        try await waitUntilIdle(queue)
    }
}
