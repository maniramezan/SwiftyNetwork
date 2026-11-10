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

    /// Refreshes credentials after `rejected` was answered with `401`, or with a `403` that
    /// ``shouldRefreshAuthorization(after:)`` accepted.
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

    /// Decides whether a `401` or `403` warrants a credential refresh.
    ///
    /// ``NetworkClient`` calls this before ``refreshAuthorization(rejecting:)``, for every `401`
    /// and for a `403` to a request this provider authorized. Return `false` when the response
    /// body or `WWW-Authenticate` header shows that a new token cannot help, for example an
    /// unrelated `401` from a backend. The client then throws ``NetworkError/unauthorized(_:)``,
    /// or ``NetworkError/forbidden(_:)`` for a `403`, without refreshing or retrying.
    ///
    /// The default implementation returns `true` for a `401` and `false` for a `403`: a `403`
    /// normally means the credentials are valid but not allowed, which a refresh cannot fix.
    /// Return `true` for a `403` only when your API uses it for a stale token, for example
    /// one issued before the user's account was upgraded:
    ///
    /// ```swift
    /// func shouldRefreshAuthorization(after response: HTTPResponse) async -> Bool {
    ///     if response.statusCode == 401 { return true }
    ///     let problem = try? response.decodeBody(APIProblem.self)
    ///     return problem?.code == "authentication_failed"
    /// }
    /// ```
    ///
    /// - Parameter response: The `401` or `403` response, including its headers and body.
    /// - Returns: `true` to refresh and retry once; `false` to fail immediately.
    func shouldRefreshAuthorization(after response: HTTPResponse) async -> Bool
}

extension AuthorizationProvider {
    /// Whether `authorization` is still what ``currentAuthorization()`` returns.
    ///
    /// Use it at the top of ``refreshAuthorization(rejecting:)`` to skip a refresh that another
    /// request already did. When it returns `false`, a newer credential exists and the caller
    /// retries with it, so return without refreshing:
    ///
    /// ```swift
    /// func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {
    ///     guard await isCurrentAuthorization(rejected) else { return }
    ///     try await tokenService.refresh()
    /// }
    /// ```
    ///
    /// If ``currentAuthorization()`` throws, there is no newer credential, so this returns `true`
    /// and the refresh proceeds.
    ///
    /// - Parameter authorization: Typically the `rejected` value passed to
    ///   ``refreshAuthorization(rejecting:)``.
    /// - Returns: `true` when the provider would still send `authorization`.
    public func isCurrentAuthorization(_ authorization: AuthorizationType) async -> Bool {
        guard let current = try? await currentAuthorization() else { return true }
        return current == authorization
    }

    /// Returns `true` for a `401`, so every `401` is refreshed once, and `false` for a `403`.
    ///
    /// - Parameter response: The `401` or `403` response.
    /// - Returns: Whether the status is `401`.
    public func shouldRefreshAuthorization(after response: HTTPResponse) async -> Bool {
        response.statusCode == 401
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
/// per refresh cycle even if many requests receive a `401` or an accepted `403` simultaneously. A `401`
/// that arrives *after* a refresh already replaced the rejected token reuses the
/// new token instead of refreshing again (see ``refreshAuthorization(rejecting:)``).
///
/// If the refresh handler calls the client this provider authorizes, give the refresh
/// endpoint ``NetworkEndpoint/usesAuthorizationProvider`` `false`. Otherwise the call carries
/// the expired token, and if it gets a `401` the client asks this provider to refresh from
/// inside its own refresh. That nested refresh throws ``ReentrantRefreshError`` instead of
/// waiting on itself forever.
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
    /// Thrown by ``refreshAuthorization(rejecting:)`` when it is called from inside this
    /// provider's own refresh handler.
    ///
    /// This happens when the refresh handler sends its request through a client that uses this
    /// provider, and that request gets a `401`. Waiting for the refresh in progress would wait for
    /// itself forever, so the nested call fails instead, and the client surfaces it as
    /// ``NetworkError/authorizationRefreshFailed(underlying:)``. To avoid it, give the refresh
    /// endpoint ``NetworkEndpoint/usesAuthorizationProvider`` `false`.
    public struct ReentrantRefreshError: Error, Sendable, Equatable, CustomStringConvertible {
        /// A description of the error.
        public var description: String {
            "The refresh handler sent a request that needed a refresh from the same provider"
        }

        /// Creates the error.
        public init() {}
    }

    /// Providers whose refresh handler is running in the current task, to detect a nested refresh.
    @TaskLocal private static var refreshingProviders: Set<ObjectIdentifier> = []

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
    ///   ``updateAccessToken(_:)`` superseded the refresh, or ``ReentrantRefreshError`` when
    ///   called from inside the refresh handler.
    public func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {
        if Self.refreshingProviders.contains(ObjectIdentifier(self)) {
            Logger.error(
                "Refresh requested from inside the refresh handler; failing it instead of waiting on itself",
                category: .auth
            )
            throw ReentrantRefreshError()
        }

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
            let refreshing = Self.refreshingProviders.union([ObjectIdentifier(self)])
            try await Self.$refreshingProviders.withValue(refreshing) {
                try await self.performRefresh(generation: generation)
            }
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
