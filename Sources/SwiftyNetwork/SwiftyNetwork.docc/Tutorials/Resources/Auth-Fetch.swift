import SwiftyNetwork

let user = try await client.request(
    UserEndpoint(userId: "me"),
    responseType: User.self
)
