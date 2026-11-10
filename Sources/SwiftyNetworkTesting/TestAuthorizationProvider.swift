import SwiftyNetwork

/// Scriptable authorization state that records refresh attempts and rejected credentials.
///
/// For tests and SwiftUI previews only; link `SwiftyNetworkTesting` from test targets, never from
/// production targets. It covers what apps usually hand-roll: a fixed bearer token
/// (`current: .bearer(token: "t")`), a refresh call counter (``refreshCallCount``), and a refresh
/// outcome you can change after creation (``setRefreshResult(_:)``).
///
/// ```swift
/// let provider = TestAuthorizationProvider(current: .bearer(token: "old"), refreshResult: true,
///     refreshedAuthorization: .bearer(token: "new"))
/// await provider.setRefreshResult(false)
/// ```
public actor TestAuthorizationProvider: AuthorizationProvider {
    /// The error thrown by a refresh scripted to fail.
    public struct RefreshFailed: Error, Sendable, Equatable {
        /// Creates the error.
        public init() {}
    }

    private var currentAuth: AuthorizationType
    private var refreshResult: Bool
    private var refreshedAuth: AuthorizationType?
    /// Number of attempted refreshes.
    public private(set) var refreshCallCount = 0
    /// Credentials rejected by the server, in order.
    public private(set) var rejectedAuthorizations: [AuthorizationType] = []
    /// `401` and `403` responses offered to ``shouldRefreshAuthorization(after:)``, in order.
    public private(set) var inspectedResponses: [HTTPResponse] = []
    private let refreshDecision: (@Sendable (HTTPResponse) -> Bool)?

    /// Creates an authorization spy.
    /// - Parameters:
    ///   - current: The initial authorization.
    ///   - refreshResult: Whether refresh should succeed. A failed refresh throws ``RefreshFailed``.
    ///   - refreshedAuthorization: Optional replacement after successful refresh.
    ///   - shouldRefresh: Optional decision for whether a `401` or `403` response warrants a refresh.
    ///     When `nil`, `401` responses are refreshed and `403` responses are not.
    public init(
        current: AuthorizationType,
        refreshResult: Bool,
        refreshedAuthorization: AuthorizationType? = nil,
        shouldRefresh: (@Sendable (HTTPResponse) -> Bool)? = nil
    ) {
        self.refreshDecision = shouldRefresh
        self.currentAuth = current
        self.refreshResult = refreshResult
        self.refreshedAuth = refreshedAuthorization
    }

    /// Changes whether later refreshes succeed. A failed refresh throws ``RefreshFailed``.
    /// - Parameter succeeds: `true` to make refreshes succeed, `false` to make them throw.
    public func setRefreshResult(_ succeeds: Bool) {
        refreshResult = succeeds
    }

    /// Changes the authorization that replaces the current one after a successful refresh.
    /// - Parameter authorization: The replacement, or `nil` to keep the current authorization.
    public func setRefreshedAuthorization(_ authorization: AuthorizationType?) {
        refreshedAuth = authorization
    }

    /// Replaces the current authorization, for example to simulate sign-in or a token rotated elsewhere.
    /// - Parameter authorization: The authorization that later requests send.
    public func setCurrentAuthorization(_ authorization: AuthorizationType) {
        currentAuth = authorization
    }

    /// Returns the current scripted authorization.
    /// - Returns: The initial or refreshed authorization.
    public func currentAuthorization() async -> AuthorizationType {
        currentAuth
    }

    /// Records a rejection and applies the scripted refresh result.
    /// - Parameter rejected: The credentials rejected by the server.
    /// - Throws: ``RefreshFailed`` when the provider was created with `refreshResult: false`.
    public func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {
        rejectedAuthorizations.append(rejected)
        refreshCallCount += 1
        guard refreshResult else { throw RefreshFailed() }
        if let refreshedAuth {
            currentAuth = refreshedAuth
        }
    }

    /// Records the `401` or `403` response and applies the scripted decision.
    /// - Parameter response: The response the server returned.
    /// - Returns: The scripted decision, or `true` when none was configured.
    public func shouldRefreshAuthorization(after response: HTTPResponse) async -> Bool {
        inspectedResponses.append(response)
        return refreshDecision?(response) ?? (response.statusCode == 401)
    }
}
