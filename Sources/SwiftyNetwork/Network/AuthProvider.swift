import Foundation

/// Provides authorization details for network requests and handles token refresh.
///
/// Implementers should be thread-safe and idempotent under concurrent refresh
/// requests. ``OAuthAuthorizationProvider`` provides a built-in implementation
/// that coalesces overlapping refreshes.
///
/// Example:
/// ```swift
/// struct StaticTokenProvider: AuthorizationProvider {
///     struct CannotRefresh: Error {}
///
///     let token: String
///
///     func currentAuthorization() async -> AuthorizationType {
///         .bearer(token: token)
///     }
///
///     func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {
///         throw CannotRefresh()
///     }
/// }
/// ```
public protocol AuthorizationProvider: Sendable {
    /// Returns the current authorization to apply to requests.
    ///
    /// Throw when no usable authorization exists, for example when the user is
    /// signed out or a proactive token refresh failed. ``NetworkClient`` then
    /// fails the request with ``NetworkError/authorizationUnavailable(underlying:)``
    /// without sending it, except that a `CancellationError` propagates unchanged.
    /// A provider that cannot fail can implement this without `throws`.
    ///
    /// - Returns: The authorization to apply.
    /// - Throws: Any error explaining why no authorization is available.
    func currentAuthorization() async throws -> AuthorizationType

    /// Refreshes credentials after `rejected` was answered with `401`.
    ///
    /// ``NetworkClient`` passes the exact authorization it sent. Use it to skip
    /// redundant refreshes: when several requests fail with the same expired token,
    /// only the first needs to refresh. The rest see that the current authorization
    /// already differs from the rejected one and can return immediately. This
    /// matters for servers that rotate refresh tokens, where a second refresh
    /// with a consumed refresh token fails and signs the user out.
    ///
    /// Return normally when newer authorization is available, and the client
    /// retries the request once with it. Throw when it is not; the client then
    /// throws ``NetworkError/authorizationRefreshFailed(underlying:)`` carrying
    /// your error, except that a `CancellationError` propagates unchanged.
    ///
    /// - Parameter rejected: The authorization that the server rejected.
    /// - Throws: Any error explaining why authorization could not be refreshed.
    func refreshAuthorization(rejecting rejected: AuthorizationType) async throws

    /// Decides whether a `401` warrants a credential refresh.
    ///
    /// ``NetworkClient`` calls this before ``refreshAuthorization(rejecting:)``. Return
    /// `false` when the response body or `WWW-Authenticate` header shows that a new
    /// token cannot help, for example an unrelated `401` from a backend. The client then
    /// throws ``NetworkError/unauthorized(_:)`` without refreshing or retrying.
    ///
    /// The default implementation returns `true`, which keeps the refresh-once behavior.
    ///
    /// - Parameter response: The `401` response, including its headers and body.
    /// - Returns: `true` to refresh and retry once; `false` to fail immediately.
    func shouldRefreshAuthorization(after response: HTTPErrorResponse) async -> Bool
}

extension AuthorizationProvider {
    /// Returns `true`, so every `401` is refreshed once.
    ///
    /// - Parameter response: The `401` response.
    /// - Returns: `true`.
    public func shouldRefreshAuthorization(after response: HTTPErrorResponse) async -> Bool {
        true
    }
}

/// An OAuth bearer token provider with refresh-token support.
///
/// This actor stores the active access token in memory only and serializes
/// access via actor isolation. It does **not** use Keychain or any other
/// secure storage — production apps should persist refresh tokens themselves
/// using `Security.framework` or another secure mechanism, and inject
/// refreshed tokens through the supplied refresh handler.
///
/// Concurrent refreshes are coalesced so the refresh handler runs at most once
/// per refresh cycle even if many requests receive a 401 simultaneously. A `401`
/// that arrives *after* a refresh already replaced the rejected token reuses the
/// new token instead of refreshing again (see ``refreshAuthorization(rejecting:)``).
///
/// Example:
/// ```swift
/// let provider = OAuthAuthorizationProvider(initialAccessToken: "old-token") {
///     try await tokenService.refreshAccessToken()
/// }
///
/// let configuration = NetworkClientConfiguration(authorizationProvider: provider)
/// let client = NetworkClient(configuration: configuration)
/// ```
public actor OAuthAuthorizationProvider: AuthorizationProvider {
    private var accessToken: String
    private var credentialGeneration = UUID()
    private let refreshTokenHandler: @Sendable () async throws -> String
    private var inFlightRefresh: Task<Void, any Error>?

    /// Creates an OAuth authorization provider.
    ///
    /// - Parameters:
    ///   - initialAccessToken: The initial OAuth access token to use for requests.
    ///   - refreshTokenHandler: A closure invoked to obtain a new access token.
    ///     Return the new token on success, or throw to signal refresh failure.
    ///     ``NetworkClient`` surfaces the error as
    ///     ``NetworkError/authorizationRefreshFailed(underlying:)``.
    public init(
        initialAccessToken: String,
        refreshTokenHandler: @escaping @Sendable () async throws -> String
    ) {
        self.accessToken = initialAccessToken
        self.refreshTokenHandler = refreshTokenHandler
    }

    /// Returns the current bearer token wrapped as an ``AuthorizationType``.
    public func currentAuthorization() async -> AuthorizationType {
        .bearer(token: accessToken)
    }

    /// Refreshes only if `rejected` is still the current token, coalescing concurrent calls.
    ///
    /// If another request already refreshed the token since `rejected` was
    /// sent, this returns without invoking the refresh handler, so the caller
    /// retries with the newer token. An in-flight refresh is joined rather than
    /// invoking the handler again.
    ///
    /// - Parameter rejected: The authorization the server answered with `401`.
    /// - Throws: The refresh handler's error, unless an explicit
    ///   ``updateAccessToken(_:)`` superseded the refresh.
    public func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {
        if rejected != .bearer(token: accessToken) {
            Logger.debug("Rejected token was already replaced; skipping refresh", category: .auth)
            return
        }

        if let existing = inFlightRefresh {
            try await existing.value
            return
        }

        let generation = credentialGeneration
        let task = Task<Void, any Error> { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performRefresh(generation: generation)
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        try await task.value
    }

    /// Replaces the stored access token, for example after sign-in or when
    /// the app obtains a token outside the refresh handler. An older in-flight
    /// refresh cannot overwrite this token when its handler completes.
    ///
    /// - Parameter token: The new access token to send with subsequent requests.
    public func updateAccessToken(_ token: String) {
        accessToken = token
        credentialGeneration = UUID()
    }

    /// Runs the refresh handler and stores the new token.
    private func performRefresh(generation: UUID) async throws {
        let newToken: String
        do {
            newToken = try await refreshTokenHandler()
        } catch {
            // An explicit token update supersedes a failed refresh.
            guard generation == credentialGeneration else { return }
            Logger.error("Refresh handler failed", error: error, category: .auth)
            throw error
        }
        // An explicit token update supersedes a successful refresh, too.
        guard generation == credentialGeneration else { return }
        accessToken = newToken
    }
}
