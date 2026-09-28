import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("OAuthAuthorizationProvider Tests")
struct OAuthAuthorizationProviderTests {
    @Test("OAuthAuthorizationProvider returns current bearer token")
    func currentAuthorizationReturnsBearerToken() async {
        let provider = OAuthAuthorizationProvider(
            initialAccessToken: "initial-token",
            refreshTokenHandler: { nil }
        )

        let auth = await provider.currentAuthorization()
        #expect(auth == .bearer(token: "initial-token"))
    }

    @Test("OAuthAuthorizationProvider refreshes token successfully")
    func refreshAuthorizationSucceeds() async {
        let provider = OAuthAuthorizationProvider(
            initialAccessToken: "old-token",
            refreshTokenHandler: { "new-token" }
        )

        let success = await provider.refreshAuthorizationIfNeeded()
        #expect(success == true)

        let auth = await provider.currentAuthorization()
        #expect(auth == .bearer(token: "new-token"))
    }

    @Test("OAuthAuthorizationProvider refresh fails when handler returns nil")
    func refreshAuthorizationFailsWhenHandlerReturnsNil() async {
        let provider = OAuthAuthorizationProvider(
            initialAccessToken: "old-token",
            refreshTokenHandler: { nil }
        )

        let success = await provider.refreshAuthorizationIfNeeded()
        #expect(success == false)

        let auth = await provider.currentAuthorization()
        #expect(auth == .bearer(token: "old-token"))
    }

    @Test("OAuthAuthorizationProvider coalesces concurrent refresh calls")
    func refreshAuthorizationCoalescesConcurrentCalls() async {
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

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask { await provider.refreshAuthorizationIfNeeded() }
            }
            for await result in group {
                #expect(result == true)
            }
        }

        let invocations = await counter.count
        #expect(invocations == 1, "Refresh handler should run once for coalesced concurrent callers")

        let auth = await provider.currentAuthorization()
        #expect(auth == .bearer(token: "new-token"))
    }

    @Test("A 401 for an already-replaced token reuses the new token without refreshing again")
    func refreshSkippedWhenRejectedTokenIsStale() async {
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
        #expect(await provider.refreshAuthorization(rejecting: .bearer(token: "token-0")))
        // A late 401 for the same stale token must not consume another refresh.
        #expect(await provider.refreshAuthorization(rejecting: .bearer(token: "token-0")))

        #expect(await counter.count == 1)
        #expect(await provider.currentAuthorization() == .bearer(token: "token-1"))
    }

    @Test("A 401 for the current token triggers a refresh")
    func refreshRunsWhenRejectedTokenIsCurrent() async {
        let provider = OAuthAuthorizationProvider(initialAccessToken: "old-token") { "new-token" }

        #expect(await provider.refreshAuthorization(rejecting: .bearer(token: "old-token")))
        #expect(await provider.currentAuthorization() == .bearer(token: "new-token"))
    }

    @Test("updateAccessToken replaces the token used for subsequent requests")
    func updateAccessTokenReplacesToken() async {
        let provider = OAuthAuthorizationProvider(initialAccessToken: "old-token") { nil }

        await provider.updateAccessToken("signed-in-token")

        #expect(await provider.currentAuthorization() == .bearer(token: "signed-in-token"))
    }

    @Test("Default refreshAuthorization(rejecting:) delegates to refreshAuthorizationIfNeeded")
    func defaultRejectingRefreshDelegates() async {
        let provider = TestAuthorizationProvider(current: .bearer(token: "a"), refreshResult: true)

        #expect(await provider.refreshAuthorization(rejecting: .bearer(token: "stale")))
        #expect(await provider.refreshCallCount == 1)
    }
}
