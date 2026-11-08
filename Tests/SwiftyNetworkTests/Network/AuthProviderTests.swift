import Foundation
import SwiftyNetworkTesting
import TestCommons
import Testing

@testable import SwiftyNetwork

@Suite("OAuthAuthorizationProvider Tests")
struct OAuthAuthorizationProviderTests {
    @Test("OAuthAuthorizationProvider returns current bearer token")
    func currentAuthorizationReturnsBearerToken() async {
        let provider = OAuthAuthorizationProvider(
            initialAccessToken: "initial-token",
            refreshTokenHandler: { throw RefreshError() }
        )

        let auth = await provider.currentAuthorization()
        #expect(auth == .bearer(token: "initial-token"))
    }

    @Test("OAuthAuthorizationProvider refreshes token successfully")
    func refreshAuthorizationSucceeds() async throws {
        let provider = OAuthAuthorizationProvider(
            initialAccessToken: "old-token",
            refreshTokenHandler: { "new-token" }
        )

        try await provider.refreshAuthorization(rejecting: .bearer(token: "old-token"))

        let auth = await provider.currentAuthorization()
        #expect(auth == .bearer(token: "new-token"))
    }

    @Test("OAuthAuthorizationProvider rethrows the handler's error and keeps the old token")
    func refreshAuthorizationRethrowsHandlerError() async {
        let provider = OAuthAuthorizationProvider(
            initialAccessToken: "old-token",
            refreshTokenHandler: { throw RefreshError() }
        )

        await #expect(throws: RefreshError.self) {
            try await provider.refreshAuthorization(rejecting: .bearer(token: "old-token"))
        }

        let auth = await provider.currentAuthorization()
        #expect(auth == .bearer(token: "old-token"))
    }

    @Test("OAuthAuthorizationProvider coalesces concurrent refresh calls")
    func refreshAuthorizationCoalescesConcurrentCalls() async throws {
        // Use an actor to count refresh handler invocations safely.
        actor Counter {
            private(set) var count = 0
            func increment() { count += 1 }
        }
        let counter = Counter()

        let provider = OAuthAuthorizationProvider(
            initialAccessToken: "old-token",
            refreshTokenHandler: {
                await counter.increment()
                // Yield to ensure overlap between concurrent callers.
                try? await Task.sleep(for: .milliseconds(20))
                return "new-token"
            }
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask { try await provider.refreshAuthorization(rejecting: .bearer(token: "old-token")) }
            }
            try await group.waitForAll()
        }

        let invocations = await counter.count
        #expect(invocations == 1, "Refresh handler should run once for coalesced concurrent callers")

        let auth = await provider.currentAuthorization()
        #expect(auth == .bearer(token: "new-token"))
    }

    @Test("A 401 for an already-replaced token reuses the new token without refreshing again")
    func refreshSkippedWhenRejectedTokenIsStale() async throws {
        actor Counter {
            private(set) var count = 0
            func next() -> Int {
                count += 1
                return count
            }
        }
        let counter = Counter()
        let provider = OAuthAuthorizationProvider(initialAccessToken: "token-0") {
            let next = await counter.next()
            return "token-\(next)"
        }

        // The first 401 for token-0 refreshes to token-1.
        try await provider.refreshAuthorization(rejecting: .bearer(token: "token-0"))
        // A late 401 for the same stale token must not consume another refresh.
        try await provider.refreshAuthorization(rejecting: .bearer(token: "token-0"))

        #expect(await counter.count == 1)
        #expect(await provider.currentAuthorization() == .bearer(token: "token-1"))
    }

    @Test("A 401 for the current token triggers a refresh")
    func refreshRunsWhenRejectedTokenIsCurrent() async throws {
        let provider = OAuthAuthorizationProvider(initialAccessToken: "old-token") { "new-token" }

        try await provider.refreshAuthorization(rejecting: .bearer(token: "old-token"))
        #expect(await provider.currentAuthorization() == .bearer(token: "new-token"))
    }

    @Test("updateAccessToken replaces the token used for subsequent requests")
    func updateAccessTokenReplacesToken() async {
        let provider = OAuthAuthorizationProvider(initialAccessToken: "old-token") { throw RefreshError() }

        await provider.updateAccessToken("signed-in-token")

        #expect(await provider.currentAuthorization() == .bearer(token: "signed-in-token"))
    }

    @Test("Explicit token updates supersede an in-flight refresh", arguments: [true, false])
    func explicitUpdateSupersedesRefresh(refreshSucceeds: Bool) async throws {
        let started = AsyncGate()
        let finish = AsyncGate()
        let provider = OAuthAuthorizationProvider(initialAccessToken: "old-token") {
            started.open()
            try await finish.wait()
            guard refreshSucceeds else { throw RefreshError() }
            return "stale-refresh-token"
        }
        let refresh = Task { try await provider.refreshAuthorization(rejecting: .bearer(token: "old-token")) }
        try await started.wait()
        await provider.updateAccessToken("signed-in-token")
        // A late 401 can use the explicit token without waiting for the old refresh.
        try await provider.refreshAuthorization(rejecting: .bearer(token: "old-token"))
        finish.open()
        // Superseded by the explicit update, so even a failed refresh succeeds.
        try await refresh.value
        #expect(await provider.currentAuthorization() == .bearer(token: "signed-in-token"))
    }

    @Test("TestAuthorizationProvider records rejections and throws a scripted failure")
    func testProviderScriptsRefreshFailure() async throws {
        let succeeding = TestAuthorizationProvider(
            current: .bearer(token: "a"), refreshResult: true, refreshedAuthorization: .bearer(token: "b"))
        try await succeeding.refreshAuthorization(rejecting: .bearer(token: "a"))
        #expect(await succeeding.currentAuthorization() == .bearer(token: "b"))
        #expect(await succeeding.rejectedAuthorizations == [.bearer(token: "a")])

        let failing = TestAuthorizationProvider(current: .bearer(token: "a"), refreshResult: false)
        await #expect(throws: TestAuthorizationProvider.RefreshFailed()) {
            try await failing.refreshAuthorization(rejecting: .bearer(token: "a"))
        }
        #expect(await failing.refreshCallCount == 1)
    }
}

private struct RefreshError: Error {}
