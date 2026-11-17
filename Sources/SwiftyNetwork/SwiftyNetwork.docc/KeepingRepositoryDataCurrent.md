# Keeping repository data current

Observe a cached entity, write values you already know, and revalidate with `ETag`s.

## Overview

``GenericRepository`` loads entities from the network and stores them in a ``Cache``. Beyond
fetching, it can tell every screen showing an entity when it changes, accept new values from the
app, and avoid downloading an entity the server says hasn't changed.

### Observe an entity

``GenericRepository/updates(forKey:)`` returns a stream of the values the repository stores for
a key from then on: network fetches, including the background refresh of
``CachePolicy/returnCacheAndRevalidate(maxAge:)``, and values written with
``GenericRepository/setCachedValue(_:forKey:)``.

The stream doesn't emit the value already cached, so subscribe first, then read the current
value:

```swift
let updates = await repository.updates(forKey: "feed")
let cached = try await repository.fetchResult(
    using: FeedEndpoint(),
    cacheKey: "feed",
    policy: .returnCacheAndRevalidate(maxAge: .seconds(60))
)
show(cached.value)
for await refreshed in updates {
    show(refreshed.value)
}
```

A slow consumer sees only the newest value. The stream never finishes on its own, so cancel the
consuming task when the screen goes away. Copies of a repository value share their observers;
separately created repositories don't.

### Write a value you already know

When a mutation returns the updated record, store it instead of fetching it again:

```swift
let saved = try await client.request(UpdateProfileEndpoint(), body: draft, responseType: User.self)
await repository.setCachedValue(saved, forKey: "user:123:profile")
```

Every observer of the key receives the new value, and the entry counts as fresh for
``CachePolicy/returnCacheIfNotExpired(maxAge:)``. When you don't have the new value, call
``GenericRepository/removeCachedValue(forKey:)`` so the next fetch loads it from the network.

### Revalidate with conditional requests

Create the repository with a second cache for entity tags:

```swift
let repository = GenericRepository(
    client: client,
    cache: InMemoryCache<Feed>(),
    validators: InMemoryCache<String>()
)
```

When a response carries an `ETag`, the repository stores it. The next network load for that key,
while the entity is still cached, sends `If-None-Match`. If the server answers
`304 Not Modified`, the repository keeps the cached entity, marks it as fetched now, and returns
it with ``RepositoryResult/Source/network``, without downloading or decoding the body again.

Give the validators cache at least the lifetime and capacity of the entity cache; a tag whose
entity is gone is ignored. ``CachePolicy/reloadIgnoringCache`` never sends the condition.

Write and remove entities through the repository, which keeps the tags in step. If you change
the entity cache directly, a `304` meant for the previous value could keep the wrong entity.

## See Also

- ``GenericRepository``
- ``RepositoryResult``
- ``CachePolicy``
