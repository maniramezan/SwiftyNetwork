# ``SwiftyNetworkTesting``

Test doubles for apps and libraries built on SwiftyNetwork.

## Overview

Link `SwiftyNetworkTesting` from your **test targets** and SwiftUI previews,
never from production targets:

```swift
.testTarget(
    name: "MyAppTests",
    dependencies: [
        "MyApp",
        .product(name: "SwiftyNetworkTesting", package: "SwiftyNetwork"),
    ]
)
```

``MockAPIClient`` conforms to SwiftyNetwork's `APIClient` and `NetworkDataSource`,
so it plugs into anything that accepts `any APIClient`, `GenericRepository`,
or `MutationQueue`. Stub responses per HTTP method and path, run the code
under test, then assert on ``MockAPIClient/recordedRequests``:

```swift
let client = MockAPIClient()
try await client.stub(.get, "/users/1", returning: User(id: "1", name: "Ada"))
await client.stub(.post, "/likes", with: .failure(NetworkError.timeout), .empty)

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
