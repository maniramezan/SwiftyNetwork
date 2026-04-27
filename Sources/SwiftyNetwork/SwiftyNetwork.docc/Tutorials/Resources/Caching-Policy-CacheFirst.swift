import SwiftyNetwork

let user = try await repository.fetch(
    using: UserEndpoint(userId: "123"),
    cacheKey: CacheKey.user("123", resource: "profile"),
    policy: .returnCacheElseLoad
)
