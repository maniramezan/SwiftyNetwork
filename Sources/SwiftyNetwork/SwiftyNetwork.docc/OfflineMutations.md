# Queueing mutations offline

Send mutations in the background with retry, coalescing, and persistence, using ``MutationQueue``.

## Overview

Use ``MutationQueue`` for "forgivable" mutations -- liking a post, updating a setting -- that
shouldn't block the UI on the network round trip and shouldn't be silently lost to a transient
failure. ``NetworkClient`` doesn't retry transient/5xx errors unless you opt in (see
<doc:HandlingErrorsAndRetries>); ``MutationQueue``
is the dedicated retry loop for this class of call, which also replays non-idempotent requests, with exponential backoff, coalescing by key,
and status reporting.

```swift
// The queue needs a client; give it the one with your AuthorizationProvider.
let queue = MutationQueue(client: authenticatedClient)

// Enqueue returns immediately; the network call and any retries run in the background.
let request = MutationRequest(endpoint: LikeVideoEndpoint(videoID: "42"))
await queue.enqueue(request, key: "like:video:42")

// Rapid toggling coalesces to the latest desired state instead of replaying
// every intermediate call.
let undo = MutationRequest(endpoint: UnlikeVideoEndpoint(videoID: "42"))
await queue.enqueue(undo, key: "like:video:42")

// Observe outcomes to reflect status in the UI; MutationQueue reports what
// happened, it doesn't manage optimistic UI state itself.
for await event in await queue.events() where event.key == "like:video:42" {
    switch event.status {
    case .succeeded:
        break
    case .failed(let reason):
        handleLikeFailure(reason)
    case .pending, .retrying, .waitingForConnectivity:
        break
    }
}
```

## Waiting for the result

When the caller needs the result, `enqueueAndWait` returns the response (or throws a ``MutationFailureReason``)
while retaining queue retry and coalescing behavior:

```swift
let response = try await queue.enqueueAndWait(request, key: "like:video:42")
```

## Ordering and responses

Mutations for different keys run independently and may finish in any order, so enqueue one that depends on
another only after the first succeeds. The `.succeeded` event carries the server's response, for example the
identifier of a created record:

```swift
if event.status == .succeeded, let post = try? event.response?.decodeBody(Post.self) {
    store.replaceDraft(id: event.key, with: post)
}
```

## Idempotency keys

The queue replays `POST` and `PATCH` after a timeout or a 5xx, when the server may already have applied them. If your
API supports idempotency keys, send one; it is stored with the request, so every replay sends the same key:

```swift
let request = try MutationRequest(endpoint: CreatePostEndpoint(), encodableBody: draft).addingIdempotencyKey()
```

## Handling failures

A failed mutation's `MutationFailureReason.category` tells apart the outcomes a UI handles differently:

| Category | Meaning | Typical handling |
| --- | --- | --- |
| `.offline` | No connection on the last attempt (retried first) | "You're offline" banner; enqueue again later |
| `.serverUnreachable` | The host did not resolve or accept a connection | Try again later |
| `.timedOut` | The request timed out; the server may have processed it | Refresh before retrying |
| `.rateLimited` | `429` and retries ran out | Enqueue again later |
| `.rejected` | The server refused it with a 4xx (other than 401/408/429); retrying won't help | Roll back; show `reason.response` details |
| `.unauthorized` | `401` and the token could not be refreshed, or the provider had no authorization | Prompt sign-in |
| `.serverError` | The server failed with a 5xx (retried first) | Generic error |
| `.insecureConnection` | The TLS connection was untrusted, for example a rejected certificate pin | "Can't connect securely" |
| `.cancelled` | `cancel(_:)` or `cancelAll()` ended it | Nothing |
| `.other` | Encoding, decoding, invalid URL, or a non-``NetworkError`` | Generic error |

`reason.statusCode` and `reason.response` carry the HTTP details for `.rejected`, `.unauthorized`, and
`.serverError`, and `reason.isTransient` says whether the queue gave up only because retries ran out:

```swift
func handleLikeFailure(_ reason: MutationFailureReason) {
    switch reason.category {
    case .cancelled:
        return
    case .offline, .serverUnreachable, .timedOut:
        showBanner("You're offline. Your like will need to be sent again.")
    case .rejected:
        rollBackLike()
        showError(try? reason.response?.decodeBody(APIError.self))
    case .unauthorized:
        promptSignIn()
    case .rateLimited, .serverError, .insecureConnection, .other:
        showBanner("Couldn't save your like.")
    }
}
```

## Persisting mutations and waiting for connectivity

Persistence is pluggable via the ``MutationStore`` protocol. ``InMemoryMutationStore`` ships as the
default; mutations are lost if the process is killed. ``FileMutationStore`` persists pending requests
so they can be replayed after relaunch:
Because ``MutationRequest`` is `Codable`, a durable store can serialize "which endpoint plus what
body" directly and replay it on the next launch via `resumePendingMutations()`. The encoded form carries a
schema `version`, and decoding rejects a version newer than the library understands.

```swift
let directory = URL.applicationSupportDirectory.appending(path: "PendingMutations", directoryHint: .isDirectory)
let queue = MutationQueue(client: authenticatedClient, store: FileMutationStore(directory: directory)) {
    await NetworkMonitor.shared.waitUntilReachable()
}
await queue.resumePendingMutations() // call once at startup
```

By default an offline failure uses up a retry like any other, so a mutation is dropped within a minute of
going offline. With a durable store, pass `waitForConnectivity` as above: an offline attempt then reports
`.waitingForConnectivity`, stays in the store, and is retried once the closure returns, without using up a retry.

## Limiting concurrent requests

Every key's mutation is sent as soon as it is enqueued, and ``MutationQueue/resumePendingMutations()``
sends everything that was persisted at once. Pass `maxConcurrentMutations` to cap how many requests are on
the wire, so a launch after a long offline period does not open dozens of connections together. Mutations
over the limit stay `.pending` and are sent in the order they became ready:

```swift
let queue = MutationQueue(
    client: authenticatedClient,
    store: FileMutationStore(directory: directory),
    maxConcurrentMutations: 4
) {
    await NetworkMonitor.shared.waitUntilReachable()
}
```

``MutationQueue/pendingKeys()`` returns the keys that have not finished, for a "3 changes waiting to sync" label.

## Credentials

A ``MutationRequest`` never captures credentials: its `authorization` is always `.none`, so every attempt,
including a replay after relaunch, is authorized by the client's ``AuthorizationProvider``, and a `401`
refreshes the token instead of replaying a stale one. An endpoint's own `authorization` is dropped (with a
logged warning) when you build a ``MutationRequest`` from it.

> Important: Headers and bodies are persisted as given. Keep secrets out of them, and store durable
> mutations securely anyway, since bodies can contain user data.
