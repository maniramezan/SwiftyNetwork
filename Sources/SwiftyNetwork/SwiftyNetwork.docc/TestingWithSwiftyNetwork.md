# Testing with SwiftyNetwork

Use SwiftyNetwork's test doubles in unit tests and SwiftUI previews.

## Overview

SwiftyNetwork ships its test doubles in the `SwiftyNetwork` module itself, behind the `Testing`
SPI. Import them only where you need them:

```swift
@_spi(Testing) import SwiftyNetwork
import Testing
```

Your test target needs no extra product, only the `SwiftyNetwork` product your app already
links. Don't import the `Testing` SPI from production code or expose its types in production APIs.

The doubles are part of the core module, not a separate library product, so a test target always
uses the same copy of SwiftyNetwork as the app. A separate testing module would statically link a
second copy into a test bundle when an Xcode app loads SwiftyNetwork through dynamic frameworks, so
casts to ``NetworkError`` and retroactive conformances would fail.

Because the doubles are SPI, they are not listed in this documentation. Their doc comments are
available in Xcode's Quick Help once you add the SPI import.

### Mocking requests

`MockAPIClient` conforms to ``APIClient``, so it plugs into anything that accepts
`any APIClient`, such as ``GenericRepository`` or ``MutationQueue``. Stub responses per HTTP
method and path, run the code under test, then assert on `recordedRequests` or
`requests(to:)`, which return `RecordedRequest` snapshots:

```swift
let client = MockAPIClient()
try await client.stub(.get, "/users/1", returning: User(id: "1", name: "Ada"))
await client.stub(.post, "/likes", with: .failure(NetworkError.timeout(nil)), .empty)

let queue = MutationQueue(client: client, retryPolicy: .immediate())
await queue.enqueue(MutationRequest(endpoint: LikeEndpoint(id: "1")), key: "like:1")

let likes = await client.requests(to: "/likes")
```

Responses for a route are consumed in order and the last one repeats. A request that matches no
stub throws `MockAPIClient.UnstubbedRequestError` unless you set a fallback with
`setFallback(_:)`.

### Authorization and instrumentation

Inject these spies into your network configuration to observe credential refresh and request
lifecycle events without defining app-specific copies:

- `TestAuthorizationProvider` is a scriptable ``AuthorizationProvider``. It covers the usual
  hand-written fixture: a fixed bearer token (`current: .bearer(token: "t")`), a refresh counter
  (`refreshCallCount`), the credentials the server rejected (`rejectedAuthorizations`), and a
  refresh outcome you can change after creation.
- `NetworkInstrumentationRecorder` is a ``NetworkInstrumentation`` that records every started,
  retried, completed, and failed event in delivery order.

```swift
let provider = TestAuthorizationProvider(current: .bearer(token: "old"), refreshResult: false)
await provider.setRefreshedAuthorization(.bearer(token: "new"))
await provider.setRefreshResult(true)
```

### Retry policies

``NetworkRetryPolicy`` and ``MutationRetryPolicy`` have a zero-wait `.immediate()` form built on
`BackoffPolicy.immediate`, which also ignores `Retry-After`, so a scripted `429` never makes a
test sleep:

```swift
let configuration = NetworkClientConfiguration(retryPolicy: .immediate(maxRetries: 2))
let queue = MutationQueue(client: client, retryPolicy: .immediate())
```
