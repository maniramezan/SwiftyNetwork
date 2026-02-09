import Foundation

/// Provides authorization details for network requests and handles token refresh operations.
///
/// Implementers should handle secure token storage and provide thread-safe access to authorization data.
public protocol AuthorizationProvider: Sendable {
    /// Returns the current authorization type to apply to requests.
    ///
    /// - Returns: The authorization type containing the current authentication credentials.
    func currentAuthorization() async -> AuthorizationType

    /// Attempts to refresh authorization credentials if needed.
    ///
    /// This method should be called when a request receives an unauthorized response.
    /// Implementations should handle token refresh logic, including secure storage updates.
    ///
    /// - Returns: `true` if the authorization was successfully refreshed; otherwise, `false`.
    func refreshAuthorizationIfNeeded() async -> Bool
}

/// A secure OAuth bearer token provider with automatic refresh capability.
///
/// This implementation provides thread-safe access to OAuth tokens and handles
/// automatic token refresh when credentials become invalid.
///
/// For production use, consider storing refresh tokens securely in Keychain
/// and implementing proper OAuth 2.0 refresh token grant flows.
public actor OAuthAuthorizationProvider: AuthorizationProvider {
    private var accessToken: String
    private let refreshTokenHandler: @Sendable () async -> String?

    /// Creates an OAuth authorization provider with initial credentials and refresh capability.
    ///
    /// - Parameters:
    ///   - initialAccessToken: The initial OAuth access token to use for requests.
    ///   - refreshTokenHandler: A closure that attempts to refresh the token when needed.
    ///     Should return the new access token on success, or `nil` on failure.
    public init(
        initialAccessToken: String,
        refreshTokenHandler: @escaping @Sendable () async -> String?
    ) {
        self.accessToken = initialAccessToken
        self.refreshTokenHandler = refreshTokenHandler
    }

    /// Returns the current authorization type to apply to requests.
    ///
    /// - Returns: The authorization type representing the current credentials (typically a bearer token).
    public func currentAuthorization() async -> AuthorizationType {
        .bearer(token: accessToken)
    }

    /// Attempts to refresh the authorization credentials.
    ///
    /// Implementations should perform any required network calls or secure storage
    /// updates to obtain new credentials. This method returns `true` when a new
    /// access token was obtained and stored, otherwise `false`.
    ///
    /// - Returns: `true` if refresh succeeded and the provider updated its credentials; `false` otherwise.
    public func refreshAuthorizationIfNeeded() async -> Bool {
        guard let newToken = await refreshTokenHandler() else {
            return false
        }

        self.accessToken = newToken
        return true
    }
}
