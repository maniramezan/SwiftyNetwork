import SwiftyNetwork

/// Scriptable authorization state that records refresh attempts and rejected credentials.
public actor TestAuthorizationProvider: AuthorizationProvider {
    /// The error thrown by a refresh scripted to fail.
    public struct RefreshFailed: Error, Sendable, Equatable {
        /// Creates the error.
        public init() {}
    }

    private var currentAuth: AuthorizationType
    private let refreshResult: Bool
    private let refreshedAuth: AuthorizationType?
    /// Number of attempted refreshes.
    public private(set) var refreshCallCount = 0
    /// Credentials rejected by the server, in order.
    public private(set) var rejectedAuthorizations: [AuthorizationType] = []
    /// `401` responses offered to ``shouldRefreshAuthorization(after:)``, in order.
    public private(set) var inspectedResponses: [HTTPResponse] = []
    private let refreshDecision: (@Sendable (HTTPResponse) -> Bool)?

    /// Creates an authorization spy.
    /// - Parameters:
    ///   - current: The initial authorization.
    ///   - refreshResult: Whether refresh should succeed. A failed refresh throws ``RefreshFailed``.
    ///   - refreshedAuthorization: Optional replacement after successful refresh.
    ///   - shouldRefresh: Optional decision for whether a `401` response warrants a refresh.
    ///     When `nil`, every `401` is refreshed.
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

    /// Records the `401` response and applies the scripted decision.
    /// - Parameter response: The `401` response the server returned.
    /// - Returns: The scripted decision, or `true` when none was configured.
    public func shouldRefreshAuthorization(after response: HTTPResponse) async -> Bool {
        inspectedResponses.append(response)
        return refreshDecision?(response) ?? true
    }
}
