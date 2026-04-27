import SwiftyNetwork

let provider = OAuthAuthorizationProvider(
    initialAccessToken: "initial-token"
) {
    // Call your refresh-token endpoint here and return the new access token.
    return await TokenStore.shared.refreshAccessToken()
}

let configuration = NetworkClientConfiguration(
    authorizationProvider: provider,
    maxAuthRefreshAttempts: 1
)

let client = NetworkClient(configuration: configuration)
