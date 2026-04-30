import Foundation

/// Provides authorization details for network requests and handles token refresh.
///
/// Implementers should be thread-safe and idempotent under concurrent refresh
/// requests. ``OAuthAuthorizationProvider`` provides a built-in implementation
/// that coalesces overlapping refreshes.
///
/// Example:
/// ```swift
/// actor StaticTokenProvider: AuthorizationProvider {
///     let token: String
///
///     init(token: String) {
///         self.token = token
///     }
///
///     func currentAuthorization() async -> AuthorizationType {
///         .bearer(token: token)
///     }
///
///     func refreshAuthorizationIfNeeded() async -> Bool {
///         false
///     }
/// }
/// ```
public protocol AuthorizationProvider: Sendable {
    /// Returns the current authorization to apply to requests.
    func currentAuthorization() async -> AuthorizationType

    /// Attempts to refresh authorization credentials.
    ///
    /// Called when a request receives an unauthorized response.
    ///
    /// - Returns: `true` if the authorization was successfully refreshed; otherwise `false`.
    func refreshAuthorizationIfNeeded() async -> Bool
}

/// An OAuth bearer token provider with refresh-token support.
///
/// This actor stores the active access token in memory only and serializes
/// access via actor isolation. It does **not** use Keychain or any other
/// secure storage — production apps should persist refresh tokens themselves
/// using `Security.framework` or another secure mechanism, and inject
/// refreshed tokens through the supplied refresh handler.
///
/// Concurrent calls to ``refreshAuthorizationIfNeeded()`` are coalesced so the
/// refresh handler runs at most once per refresh cycle even if many requests
/// receive a 401 simultaneously.
///
/// Example:
/// ```swift
/// let provider = OAuthAuthorizationProvider(initialAccessToken: "old-token") {
///     await tokenService.refreshAccessToken()
/// }
///
/// let configuration = NetworkClientConfiguration(authorizationProvider: provider)
/// let client = NetworkClient(configuration: configuration)
/// ```
public actor OAuthAuthorizationProvider: AuthorizationProvider {
    private var accessToken: String
    private let refreshTokenHandler: @Sendable () async -> String?
    private var inFlightRefresh: Task<Bool, Never>?

    /// Creates an OAuth authorization provider.
    ///
    /// - Parameters:
    ///   - initialAccessToken: The initial OAuth access token to use for requests.
    ///   - refreshTokenHandler: A closure invoked to obtain a new access token.
    ///     Return the new token on success, or `nil` to signal refresh failure.
    public init(
        initialAccessToken: String,
        refreshTokenHandler: @escaping @Sendable () async -> String?
    ) {
        self.accessToken = initialAccessToken
        self.refreshTokenHandler = refreshTokenHandler
    }

    /// Returns the current bearer token wrapped as an ``AuthorizationType``.
    public func currentAuthorization() async -> AuthorizationType {
        .bearer(token: accessToken)
    }

    /// Attempts to refresh the access token, coalescing concurrent calls.
    ///
    /// If a refresh is already in flight, this awaits its result rather than
    /// invoking the refresh handler again.
    ///
    /// - Returns: `true` if a new token was stored; `false` otherwise.
    public func refreshAuthorizationIfNeeded() async -> Bool {
        if let existing = inFlightRefresh {
            return await existing.value
        }

        let task = Task<Bool, Never> { [weak self] in
            await self?.performRefresh() ?? false
        }
        inFlightRefresh = task

        let result = await task.value
        inFlightRefresh = nil
        return result
    }

    /// Runs the refresh handler and applies the new token if one was returned.
    private func performRefresh() async -> Bool {
        let newToken = await refreshTokenHandler()
        if let newToken {
            accessToken = newToken
            return true
        }
        return false
    }
}
