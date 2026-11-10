import Foundation
import TestCommons
import Testing

@testable import SwiftyNetwork

@Suite("AuthorizationRefreshCoalescer", .timeLimit(.minutes(1)))
struct AuthorizationRefreshCoalescerTests {
    private struct RefreshFailed: Error, Equatable {}

    private actor Counter {
        private(set) var count = 0

        func increment() { count += 1 }
    }

    /// A provider whose token the tests replace, and whose first `currentAuthorization()` call can be
    /// held after it reads the token, to simulate a staleness check that suspends.
    private actor SwappableProvider: AuthorizationProvider {
        private var token: String
        private var calls = 0
        private let holdFirstCall: Bool
        nonisolated let firstCallReached = AsyncGate()
        nonisolated let releaseFirstCall = AsyncGate()

        init(token: String, holdFirstCall: Bool = false) {
            self.token = token
            self.holdFirstCall = holdFirstCall
        }

        func currentAuthorization() async throws -> AuthorizationType {
            calls += 1
            let observed = token
            if holdFirstCall, calls == 1 {
                firstCallReached.open()
                try await releaseFirstCall.wait()
            }
            return .bearer(token: observed)
        }

        func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {}

        func store(_ newToken: String) { token = newToken }
    }

    /// A custom provider that coalesces refreshes the way a consumer would.
    private actor CoalescingProvider: AuthorizationProvider {
        private let refreshes = AuthorizationRefreshCoalescer()
        private var token = "old"
        let refreshCount = Counter()
        private(set) var rejectionCount = 0
        nonisolated let refreshStarted = AsyncGate()
        nonisolated let finishRefresh = AsyncGate()

        func currentAuthorization() async -> AuthorizationType { .bearer(token: token) }

        func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {
            rejectionCount += 1
            try await refreshes.refresh(rejecting: rejected, of: self) {
                await self.refreshCount.increment()
                self.refreshStarted.open()
                try await self.finishRefresh.wait()
                await self.store("new")
            }
        }

        private func store(_ newToken: String) { token = newToken }
    }

    private func waitForJoiners(_ count: Int, on coalescer: AuthorizationRefreshCoalescer) async {
        while await coalescer.joinedCallers < count { await Task.yield() }
    }

    // MARK: - Forced refresh

    @Test("Forced refreshes that arrive during a running refresh share one refresh that starts after it")
    func forcedRefreshesRunAfterOlderRefreshAndCoalesce() async throws {
        let coalescer = AuthorizationRefreshCoalescer()
        let olderRuns = Counter()
        let forcedRuns = Counter()
        let forcedReturned = Counter()
        let olderStarted = AsyncGate()
        let finishOlder = AsyncGate()
        let finishForced = AsyncGate()

        let older = Task {
            try await coalescer.refresh {
                await olderRuns.increment()
                olderStarted.open()
                try await finishOlder.wait()
            }
        }
        try await olderStarted.wait()
        let forced = (0..<9).map { _ in
            Task {
                try await coalescer.refresh {
                    await forcedRuns.increment()
                    try await finishForced.wait()
                }
                await forcedReturned.increment()
            }
        }
        // All nine wait on the older refresh, which must not satisfy them.
        await waitForJoiners(9, on: coalescer)
        finishOlder.open()
        try await older.value
        // One of them starts the next refresh and the other eight join it. Stop waiting if they
        // all returned instead, which happens only when the older refresh wrongly satisfied them.
        while await coalescer.joinedCallers < 17, await forcedReturned.count < 9 { await Task.yield() }
        finishForced.open()

        for call in forced { try await call.value }
        #expect(await olderRuns.count == 1)
        #expect(await forcedRuns.count == 1)
    }

    @Test("A forced refresh ignores the failure of a refresh that started before it")
    func forcedRefreshIgnoresOlderFailure() async throws {
        let coalescer = AuthorizationRefreshCoalescer()
        let forcedRuns = Counter()
        let olderStarted = AsyncGate()
        let finishOlder = AsyncGate()

        let older = Task {
            try await coalescer.refresh {
                olderStarted.open()
                try await finishOlder.wait()
                throw RefreshFailed()
            }
        }
        try await olderStarted.wait()
        let forced = Task { try await coalescer.refresh { await forcedRuns.increment() } }
        await waitForJoiners(1, on: coalescer)
        finishOlder.open()

        await #expect(throws: RefreshFailed.self) { try await older.value }
        try await forced.value
        #expect(await forcedRuns.count == 1)
    }

    @Test("A failed refresh reaches every joiner and is not remembered")
    func failureReachesJoinersAndIsRetried() async throws {
        let coalescer = AuthorizationRefreshCoalescer()
        let provider = SwappableProvider(token: "old")
        let counter = Counter()
        let started = AsyncGate()
        let finish = AsyncGate()

        let first = Task {
            try await coalescer.refresh(rejecting: .bearer(token: "old"), of: provider) {
                await counter.increment()
                started.open()
                try await finish.wait()
                throw RefreshFailed()
            }
        }
        try await started.wait()
        let joiner = Task {
            try await coalescer.refresh(rejecting: .bearer(token: "old"), of: provider) { await counter.increment() }
        }
        await waitForJoiners(1, on: coalescer)
        finish.open()

        await #expect(throws: RefreshFailed.self) { try await first.value }
        await #expect(throws: RefreshFailed.self) { try await joiner.value }
        #expect(await counter.count == 1)

        try await coalescer.refresh { await counter.increment() }
        #expect(await counter.count == 2)
    }

    @Test("A refresh requested from inside the running refresh throws instead of waiting on itself")
    func nestedRefreshThrows() async throws {
        let coalescer = AuthorizationRefreshCoalescer()

        await #expect(throws: ReentrantRefreshError.self) {
            try await coalescer.refresh {
                try await coalescer.refresh {}
            }
        }
        await #expect(throws: ReentrantRefreshError.self) {
            try await coalescer.refresh {
                try await coalescer.refresh(rejecting: .none, of: SwappableProvider(token: "t")) {}
            }
        }
    }

    @Test("Another coalescer can refresh from inside a running refresh")
    func nestedRefreshOnAnotherCoalescerRuns() async throws {
        let outer = AuthorizationRefreshCoalescer()
        let inner = AuthorizationRefreshCoalescer()
        let counter = Counter()

        try await outer.refresh {
            try await inner.refresh { await counter.increment() }
        }

        #expect(await counter.count == 1)
    }

    @Test("Canceling callers does not cancel the shared refresh")
    func cancellationDoesNotCancelSharedWork() async throws {
        let coalescer = AuthorizationRefreshCoalescer()
        let started = AsyncGate()
        let finish = AsyncGate()
        let sawCancellation = Counter()

        let first = Task {
            try await coalescer.refresh {
                started.open()
                try await finish.wait()
                if Task.isCancelled { await sawCancellation.increment() }
            }
        }
        try await started.wait()
        let joiner = Task {
            try await coalescer.refresh(rejecting: .bearer(token: "t"), of: SwappableProvider(token: "t")) {}
        }
        await waitForJoiners(1, on: coalescer)
        first.cancel()
        joiner.cancel()
        finish.open()

        try await first.value
        try await joiner.value
        #expect(await sawCancellation.count == 0)
    }

    // MARK: - Refresh after a rejection

    @Test("A rejection of an already-replaced authorization skips the refresh")
    func staleRejectionSkips() async throws {
        let coalescer = AuthorizationRefreshCoalescer()
        let provider = SwappableProvider(token: "new")
        let counter = Counter()

        try await coalescer.refresh(rejecting: .bearer(token: "old"), of: provider) {
            await counter.increment()
        }

        #expect(await counter.count == 0)
    }

    @Test("Concurrent rejections of the current authorization refresh once")
    func currentRejectionsCoalesce() async throws {
        let coalescer = AuthorizationRefreshCoalescer()
        let provider = SwappableProvider(token: "old")
        let counter = Counter()
        let started = AsyncGate()
        let finish = AsyncGate()
        let operation: @Sendable () async throws -> Void = {
            await counter.increment()
            started.open()
            try await finish.wait()
            await provider.store("new")
        }

        let first = Task { try await coalescer.refresh(rejecting: .bearer(token: "old"), of: provider, operation) }
        try await started.wait()
        let joiners = (0..<9).map { _ in
            Task { try await coalescer.refresh(rejecting: .bearer(token: "old"), of: provider, operation) }
        }
        await waitForJoiners(9, on: coalescer)
        finish.open()

        try await first.value
        for joiner in joiners { try await joiner.value }
        #expect(await counter.count == 1)
        #expect(try await provider.currentAuthorization() == .bearer(token: "new"))

        // A late rejection of the replaced token does not refresh again.
        try await coalescer.refresh(rejecting: .bearer(token: "old"), of: provider, operation)
        #expect(await counter.count == 1)
    }

    @Test("A refresh that finishes during another caller's staleness check is not repeated")
    func refreshDuringStalenessCheckIsNotRepeated() async throws {
        let coalescer = AuthorizationRefreshCoalescer()
        let provider = SwappableProvider(token: "old", holdFirstCall: true)
        let counter = Counter()
        let operation: @Sendable () async throws -> Void = {
            await counter.increment()
            await provider.store("new")
        }

        // The late caller reads "old", then is held before the coalescer sees the result.
        let late = Task { try await coalescer.refresh(rejecting: .bearer(token: "old"), of: provider, operation) }
        try await provider.firstCallReached.wait()
        // A whole refresh starts and finishes meanwhile.
        try await coalescer.refresh(rejecting: .bearer(token: "old"), of: provider, operation)
        provider.releaseFirstCall.open()

        try await late.value
        #expect(await counter.count == 1)
    }

    @Test("A provider without authorization is refreshed")
    func throwingCurrentAuthorizationRefreshes() async throws {
        struct SignedOut: AuthorizationProvider {
            struct NoSession: Error {}

            func currentAuthorization() async throws -> AuthorizationType { throw NoSession() }
            func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {}
        }
        let coalescer = AuthorizationRefreshCoalescer()
        let counter = Counter()

        try await coalescer.refresh(rejecting: .none, of: SignedOut()) { await counter.increment() }

        #expect(await counter.count == 1)
    }

    @Test("A custom staleness check refreshes when a different value is not usable")
    func customStalenessCheckRefreshesWithoutUsableAuthorization() async throws {
        actor NoTokenProvider: AuthorizationProvider {
            private var authorization: AuthorizationType = .none
            func currentAuthorization() async -> AuthorizationType { authorization }
            func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {}
            func store(_ value: AuthorizationType) { authorization = value }
        }
        let coalescer = AuthorizationRefreshCoalescer()
        let provider = NoTokenProvider()
        let counter = Counter()
        let rejected = AuthorizationType.bearer(token: "expired")

        try await coalescer.refresh(rejecting: rejected, of: provider) {
            await counter.increment()
        }
        #expect(await counter.count == 0)

        let check: @Sendable () async -> Bool = {
            let current = await provider.currentAuthorization()
            return current == .none || current == rejected
        }
        let refresh: @Sendable () async -> Void = {
            await counter.increment()
            await provider.store(.bearer(token: "new"))
        }
        try await coalescer.refresh(rejecting: rejected, isCurrentAuthorization: check, refresh)
        try await coalescer.refresh(rejecting: rejected, isCurrentAuthorization: check, refresh)
        #expect(await counter.count == 1)
    }

    // MARK: - Through NetworkClient

    @Test("Concurrent 401s for a custom provider refresh once and replay with the new token")
    func networkClientConcurrent401sRefreshOnce() async throws {
        let stub = try TestHTTPStub()
        defer { stub.invalidate() }
        let ids = (0..<5).map { _ in UUID().uuidString }
        for id in ids { stub.setResponses([.status(401), .status(204)], for: id) }
        let provider = CoalescingProvider()
        let client = NetworkClient(
            configuration: NetworkClientConfiguration(
                session: stub.session,
                authorizationProvider: provider,
                authRefreshDelay: .zero
            )
        )

        defer { provider.finishRefresh.open() }
        let requests = ids.map { id in
            Task { try await client.request(makeEndpointWithTestId(id)) }
        }
        try await provider.refreshStarted.wait()
        _ = try await waitUntil(
            timeout: testTimeout,
            operation: { await provider.rejectionCount },
            matching: { $0 == ids.count }
        )
        provider.finishRefresh.open()
        for request in requests { try await request.value }

        #expect(await provider.refreshCount.count == 1)
        for id in ids {
            #expect(stub.getLastRequestHeaders(for: id)?["Authorization"] == "Bearer new")
        }
    }
}
