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
}
