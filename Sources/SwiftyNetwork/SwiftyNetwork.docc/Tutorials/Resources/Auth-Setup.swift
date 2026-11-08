import SwiftyNetwork

let provider = OAuthAuthorizationProvider(
    initialAccessToken: "initial-token"
) {
    // Call your refresh-token endpoint here and return the new access token, or throw.
    try await TokenStore.shared.refreshAccessToken()
}

let configuration = NetworkClientConfiguration(
    authorizationProvider: provider,
    maxAuthRefreshAttempts: 1
)

let client = NetworkClient(configuration: configuration)
