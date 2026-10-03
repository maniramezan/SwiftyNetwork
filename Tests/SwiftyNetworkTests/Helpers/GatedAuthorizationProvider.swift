import SwiftyNetwork
import TestCommons

actor GatedAuthorizationProvider: AuthorizationProvider {
    private(set) var callCount = 0
    nonisolated let release = AsyncGate()

    func currentAuthorization() async -> AuthorizationType {
        callCount += 1
        try? await release.wait()
        return .none
    }

    func refreshAuthorizationIfNeeded() async -> Bool { false }
}
