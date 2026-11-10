import Foundation

/// Provides authorization details for network requests and handles token refresh.
///
/// Implementers should be thread-safe and idempotent under concurrent refresh
/// requests. ``OAuthAuthorizationProvider`` provides a built-in implementation
/// that coalesces overlapping refreshes; a custom provider gets the same behavior
/// by routing its refresh through an ``AuthorizationRefreshCoalescer``.
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
    /// request already did. It does not stop requests that fail together from each refreshing;
    /// ``AuthorizationRefreshCoalescer`` does both. A different value makes this return `false`;
    /// this is safe to skip only if that value represents a usable replacement:
    ///
    /// ```swift
    /// func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {
    ///     guard await isCurrentAuthorization(rejected) else { return }
    ///     try await tokenService.refresh()
    /// }
    /// ```
    ///
    /// If ``currentAuthorization()`` throws, there is no newer credential, so this returns `true`.
    /// If the provider instead uses a value such as ``AuthorizationType/none`` to represent no
    /// usable credential, that value compares unequal to a rejected bearer token and this returns
    /// `false` even though refresh may still be needed. Use a custom check, or pass a probe
    /// provider that throws for that sentinel to
    /// ``AuthorizationRefreshCoalescer/refresh(rejecting:of:_:)``. The probe is only used for
    /// the check and need not change how the real provider authorizes requests.
    ///
    /// - Parameter authorization: Typically the `rejected` value passed to
    ///   ``refreshAuthorization(rejecting:)``.
    /// - Returns: `true` when the provider returns `authorization` or throws.
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
    /// This is ``SwiftyNetwork/ReentrantRefreshError``, which every
    /// ``AuthorizationRefreshCoalescer`` throws for a nested refresh.
    public typealias ReentrantRefreshError = SwiftyNetwork.ReentrantRefreshError

    private var accessToken: String
    private var credentialGeneration = UUID()
    private let refreshTokenHandler: @Sendable () async throws -> String
    private let refreshes = AuthorizationRefreshCoalescer()

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
        let generation = credentialGeneration
        try await refreshes.refresh(rejecting: rejected, of: self) { [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performRefresh(generation: generation)
        }
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
            throw error
        }
        // An explicit token update supersedes a successful refresh, too.
        guard generation == credentialGeneration else { return }
        accessToken = newToken
    }
}
