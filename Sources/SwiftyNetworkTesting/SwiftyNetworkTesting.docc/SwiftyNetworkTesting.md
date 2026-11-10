# ``SwiftyNetworkTesting``

Test doubles for apps and libraries built on SwiftyNetwork.

## Overview

Link `SwiftyNetwork` from your app or library target and `SwiftyNetworkTesting` only from its
**test target**. `SwiftyNetworkTesting` already depends on `SwiftyNetwork`, so do not add the core
product to the test target again; this keeps Swift Package Manager's dependency graph to one copy
of `SwiftyNetwork`. Never link `SwiftyNetworkTesting` from production targets:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "SwiftyNetwork", package: "SwiftyNetwork"),
    ]
),
.testTarget(
    name: "MyAppTests",
    dependencies: [
        "MyApp",
        .product(name: "SwiftyNetworkTesting", package: "SwiftyNetwork"),
    ]
)
```

``MockAPIClient`` conforms to SwiftyNetwork's `APIClient`,
so it plugs into anything that accepts `any APIClient`, `GenericRepository`,
or `MutationQueue`. Stub responses per HTTP method and path, run the code
under test, then assert on ``MockAPIClient/recordedRequests``:

```swift
let client = MockAPIClient()
try await client.stub(.get, "/users/1", returning: User(id: "1", name: "Ada"))
await client.stub(.post, "/likes", with: .failure(NetworkError.timeout(nil)), .empty)

let queue = MutationQueue(client: client, retryPolicy: .immediate())
await queue.enqueue(MutationRequest(endpoint: LikeEndpoint(id: "1")), key: "like:1")

let likes = await client.requests(to: "/likes")
```

Responses for a route are consumed in order and the last one repeats. A
request that matches no stub throws ``MockAPIClient/UnstubbedRequestError``
unless you set a fallback with ``MockAPIClient/setFallback(_:)``.

## Topics

### Mocking Requests

- ``MockAPIClient``
- ``RecordedRequest``

### Authorization and instrumentation

- ``TestAuthorizationProvider``
- ``NetworkInstrumentationRecorder``

Inject these spies into your network configuration to observe credential refresh
and request lifecycle events without defining app-specific copies.

`TestAuthorizationProvider` covers the usual hand-written fixture: a fixed bearer token
(`current: .bearer(token: "t")`), a refresh counter (`refreshCallCount`), the credentials the server
rejected (`rejectedAuthorizations`), and a refresh outcome you can change after creation:

```swift
let provider = TestAuthorizationProvider(current: .bearer(token: "old"), refreshResult: false)
await provider.setRefreshedAuthorization(.bearer(token: "new"))
await provider.setRefreshResult(true)
```

### Retry policies

Both policies have a zero-wait `.immediate()` form built on `BackoffPolicy.immediate`, which also
ignores `Retry-After`, so a scripted `429` never makes a test sleep:

```swift
let configuration = NetworkClientConfiguration(retryPolicy: .immediate(maxRetries: 2))
let queue = MutationQueue(client: client, retryPolicy: .immediate())
```

These helpers extend `SwiftyNetwork.NetworkRetryPolicy`,
`SwiftyNetwork.MutationRetryPolicy`, and `SwiftyNetwork.BackoffPolicy`.
