import SwiftyNetwork

actor SessionAuthProvider: AuthorizationProvider {
    private var sessionToken: String

    init(sessionToken: String) {
        self.sessionToken = sessionToken
    }

    func currentAuthorization() async -> AuthorizationType {
        .custom(header: "X-Session", value: sessionToken)
    }

    func refreshAuthorizationIfNeeded() async -> Bool {
        // Reauthenticate via your backend, update sessionToken, and return whether it succeeded.
        return false
    }
}
