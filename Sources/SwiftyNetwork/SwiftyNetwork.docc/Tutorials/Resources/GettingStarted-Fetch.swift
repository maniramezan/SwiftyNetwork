import SwiftyNetwork

func fetchUser(id: String) async throws -> User {
    let client = NetworkClient.shared
    let endpoint = UserEndpoint(userId: id)
    return try await client.request(endpoint, responseType: User.self)
}
