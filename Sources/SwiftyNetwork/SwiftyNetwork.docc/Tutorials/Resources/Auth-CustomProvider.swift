import SwiftyNetwork

actor SessionAuthProvider: AuthorizationProvider {
    private let refreshes = AuthorizationRefreshCoalescer()
    private var sessionToken: String

    init(sessionToken: String) {
        self.sessionToken = sessionToken
    }

    func currentAuthorization() async -> AuthorizationType {
        .custom(header: "X-Session", value: sessionToken)
    }

    func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {
        // Requests that fail together share one refresh; a stale rejection skips it.
        try await refreshes.refresh(rejecting: rejected, of: self) {
            // Reauthenticate via your backend, or throw when you can't.
            let token = try await SessionStore.shared.reauthenticate()
            await self.store(token)
        }
    }

    private func store(_ token: String) {
        sessionToken = token
    }
}
