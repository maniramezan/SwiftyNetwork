import SwiftyNetwork

let user = try await repository.fetch(
    using: UserEndpoint(userId: "123"),
    cacheKey: "user:123:profile",
    policy: .returnCacheElseLoad
)
