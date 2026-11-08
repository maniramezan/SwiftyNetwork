import SwiftyNetwork

actor SessionAuthProvider: AuthorizationProvider {
    struct SessionExpired: Error {}

    private var sessionToken: String

    init(sessionToken: String) {
        self.sessionToken = sessionToken
    }

    func currentAuthorization() async -> AuthorizationType {
        .custom(header: "X-Session", value: sessionToken)
    }

    func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {
        // Reauthenticate via your backend and update sessionToken, or throw when you can't.
        throw SessionExpired()
    }
}
