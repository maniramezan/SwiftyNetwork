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

        switch auth {
        case .bearer(let token):
            #expect(token == "initial-token")
        default:
            Issue.record("Expected bearer token authorization")
        }
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
        switch auth {
        case .bearer(let token):
            #expect(token == "new-token")
        default:
            Issue.record("Expected bearer token authorization")
        }
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
        switch auth {
        case .bearer(let token):
            #expect(token == "old-token")
        default:
            Issue.record("Expected bearer token authorization")
        }
    }
}
