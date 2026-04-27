import SwiftyNetwork

let cache = InMemoryCache<User>(maxSize: 200)
let local = CacheBasedLocalDataSource(cache: cache)
