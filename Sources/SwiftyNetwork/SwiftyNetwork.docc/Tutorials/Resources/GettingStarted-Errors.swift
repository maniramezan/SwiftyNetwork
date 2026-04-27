import SwiftyNetwork

func fetchUserHandlingErrors(id: String) async -> User? {
    do {
        return try await NetworkClient.shared.request(
            UserEndpoint(userId: id),
            responseType: User.self
        )
    } catch NetworkError.unauthorized {
        // Prompt the user to re-authenticate.
        return nil
    } catch NetworkError.notFound {
        return nil
    } catch {
        return nil
    }
}
