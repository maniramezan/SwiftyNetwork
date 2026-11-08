import SwiftyNetwork

/// Scriptable authorization state that records refresh attempts and rejected credentials.
public actor TestAuthorizationProvider: AuthorizationProvider {
    private var currentAuth: AuthorizationType
    private let refreshResult: Bool
    private let refreshedAuth: AuthorizationType?
    /// Number of attempted refreshes.
    public private(set) var refreshCallCount = 0
    /// Credentials rejected by the server, in order.
    public private(set) var rejectedAuthorizations: [AuthorizationType] = []
    /// `401` responses offered to ``shouldRefreshAuthorization(after:)``, in order.
    public private(set) var inspectedResponses: [HTTPErrorResponse] = []
    private let refreshDecision: (@Sendable (HTTPErrorResponse) -> Bool)?

    /// Creates an authorization spy.
    /// - Parameters:
    ///   - current: The initial authorization.
    ///   - refreshResult: Whether refresh should succeed.
    ///   - refreshedAuthorization: Optional replacement after successful refresh.
    ///   - shouldRefresh: Optional decision for whether a `401` response warrants a refresh.
    ///     When `nil`, every `401` is refreshed.
    public init(
        current: AuthorizationType,
        refreshResult: Bool,
        refreshedAuthorization: AuthorizationType? = nil,
        shouldRefresh: (@Sendable (HTTPErrorResponse) -> Bool)? = nil
    ) {
        self.refreshDecision = shouldRefresh
        self.currentAuth = current
        self.refreshResult = refreshResult
        self.refreshedAuth = refreshedAuthorization
    }

    /// Returns the current scripted authorization.
    /// - Returns: The initial or refreshed authorization.
    public func currentAuthorization() async -> AuthorizationType {
        currentAuth
    }

    /// Records a refresh attempt and applies the scripted result.
    /// - Returns: The configured refresh success flag.
    public func refreshAuthorizationIfNeeded() async -> Bool {
        refreshCallCount += 1
        if refreshResult, let refreshedAuth {
            currentAuth = refreshedAuth
        }
        return refreshResult
    }

    /// Records a rejection and attempts the scripted refresh.
    /// - Parameter rejected: The credentials rejected by the server.
    /// - Returns: The configured refresh success flag.
    public func refreshAuthorization(rejecting rejected: AuthorizationType) async -> Bool {
        rejectedAuthorizations.append(rejected)
        return await refreshAuthorizationIfNeeded()
    }

    /// Records the `401` response and applies the scripted decision.
    /// - Parameter response: The `401` response the server returned.
    /// - Returns: The scripted decision, or `true` when none was configured.
    public func shouldRefreshAuthorization(after response: HTTPErrorResponse) async -> Bool {
        inspectedResponses.append(response)
        return refreshDecision?(response) ?? true
    }
}
