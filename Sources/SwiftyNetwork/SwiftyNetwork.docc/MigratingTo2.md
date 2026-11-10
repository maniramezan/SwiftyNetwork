# Migrating to SwiftyNetwork 2.0

Update an app from SwiftyNetwork 1.x to 2.0.

## Overview

SwiftyNetwork 2.0 is a breaking release. It gives every HTTP error its response, uses
`Duration` for every time value, strips credentials from cross-origin redirects, and removes
several abstractions that duplicated each other. Most changes are mechanical renames that the
compiler points you to. A few change behavior without a compile error; those are marked
**Behavior change** below. Read them even if your app builds.

### Platforms and dependencies

- SwiftyNetwork 2.0 requires iOS 18 / macOS 15 and Swift 6.2, the same as 1.5. Apps on
  older OS releases can stay on 1.4.0.
- SwiftyNetwork now imports SwiftCommons internally, so SwiftCommons is not part of its API.
  If your app uses SwiftCommons, depend on it directly instead of through SwiftyNetwork.
- Point your package at 2.0:

```swift
.package(url: "https://github.com/maniramezan/SwiftyNetwork.git", from: "2.0.0")
```

### Making requests

``APIClient`` now has a single requirement, ``APIClient/response(for:responseType:)``. It
returns a ``DecodedResponse`` holding the decoded value and its ``HTTPResponse``. The
`request` methods you already call still work; they are now protocol-extension
conveniences built on top of it.

- **Custom `APIClient` conformances** implement `response(for:responseType:)` instead of
  `request(_:responseType:)`:

```swift
// 1.x
func request<T: Decodable & Sendable>(_ endpoint: any NetworkEndpoint, responseType: T.Type) async throws -> T

// 2.0
func response<T: Decodable & Sendable>(
    for endpoint: any NetworkEndpoint,
    responseType: T.Type
) async throws -> DecodedResponse<T> {
    DecodedResponse(value: try decode(...))
}
```

- To read headers of a successful response, call `response(for:responseType:)` and read
  `response.header("ETag")`.
- **Behavior change:** `responseType: Data.self` returns the raw body. In 1.x it tried to
  JSON-decode a base64 string.
- ``HTTPMethod`` is a struct, not an enum. The seven predefined methods are unchanged, and
  you can write custom ones as string literals (`let method: HTTPMethod = "PROPFIND"`). A
  `switch` over a method needs a `default` case, and `HTTPMethod.allCases` is gone.
- Keep each endpoint's ``NetworkEndpoint/baseURL`` explicit. For endpoints sharing a host and
  common headers, define an app-specific protocol refinement and provide those defaults in its
  extension; this retains compile-time enforcement while avoiding repeated properties.
- ``TypedEndpoint`` is available for endpoints with a fixed response type. Use
  ``APIClient/send(_:)`` or ``APIClient/send(_:body:)`` instead of repeating `responseType:`.
- An endpoint may also set ``NetworkEndpoint/operationName`` for low-cardinality instrumentation,
  ``NetworkEndpoint/timeout`` to override the client timeout,
  ``NetworkEndpoint/cachePolicy`` to control `URLRequest`/`URLCache` behavior, and
  ``NetworkEndpoint/isIdempotent`` to opt a server-deduplicated `POST` into request retries.
- `NetworkDataSource` is gone; depend on ``APIClient``.
  `GenericRepository(networkDataSource:localDataSource:)` is `GenericRepository(client:cache:)`.

### Configuration

- Every time value is a `Duration`: `timeout: .seconds(15)` (was `timeoutInterval: 15`),
  `authRefreshDelay: .zero` (was `retryDelay: 0`), `maxAge: .seconds(300)`. For a `Double`,
  use `duration / .seconds(1)`.
- `NetworkClientConfiguration(logLevel:)` is gone. Set ``LogLevel/current`` once for the
  whole process.
- `NetworkClientConfiguration(sslPinning:sessionConfiguration:delegateQueue:...)` is gone.
  Pass `session: pinning.makeSession(configuration: sessionConfiguration)`.
- `NetworkClient.updateConfiguration(_:)` is gone. Create a new ``NetworkClient`` instead.
- `NetworkClient.attemptCount()` is gone. Count attempts with a ``NetworkInstrumentation``
  (``NetworkRequestAttempt/attempt`` numbers each attempt of a request), or with
  `NetworkInstrumentationRecorder` from the `Testing` SPI in tests.

### Test support

- **Breaking:** The `SwiftyNetworkTesting` library product is gone. Its test doubles now live in
  the `SwiftyNetwork` module behind the `Testing` SPI. Remove the
  `.product(name: "SwiftyNetworkTesting", package: "SwiftyNetwork")` dependency from test targets,
  link `SwiftyNetwork` instead if the target doesn't already, and replace
  `import SwiftyNetworkTesting` with `@_spi(Testing) import SwiftyNetwork`. `@testable import`
  alone doesn't expose SPI, so write `@_spi(Testing) @testable import SwiftyNetwork` where you need
  both. The type names are unchanged.
- In Xcode apps that load SwiftyNetwork through dynamic frameworks, the separate product could
  link a second copy of SwiftyNetwork into the test bundle, so casts to ``NetworkError`` and
  retroactive conformances failed. With the doubles in the core module, a test bundle uses the
  app's copy. See <doc:TestingWithSwiftyNetwork>.
- `TestAuthorizationProvider` adds `setRefreshResult(_:)`, `setRefreshedAuthorization(_:)`, and
  `setCurrentAuthorization(_:)` to change its script.

### Redirects

- **Behavior change:** ``NetworkClient`` now checks every redirect against
  ``NetworkClientConfiguration/redirectPolicy``. The default,
  ``RedirectPolicy/stripCredentialsAcrossOrigins``, follows a redirect to another scheme, host,
  or port without the `Authorization`, `Proxy-Authorization`, and `Cookie` headers or the header
  an `.apiKey` or `.custom` authorization set, and refuses a redirect from `https` to `http`.
  In 1.x, `URLSession` forwarded every header to wherever the server redirected.
- A refused redirect throws ``NetworkError/unexpectedStatus(_:)`` with the `3xx` response.
- If the session you pass in has a delegate that handles redirects, nothing changes: that
  delegate still decides every redirect, and the policy is not applied.
- If your API redirects to another origin that needs the same credentials, set
  `redirectPolicy: .followAll` to keep the 1.x behavior.

### Errors

Every ``NetworkError`` case that comes from an HTTP status carries a non-optional
``HTTPResponse`` with the status code, headers, body, and `retryAfter`.

| 1.x | 2.0 |
| --- | --- |
| `.serverError(statusCode: 422, data: d)` | `.clientError(HTTPResponse(statusCode: 422, body: d))` |
| `case .serverError(let code, let data)` | `case .serverError(let response)`, then `response.statusCode`, `response.body` |
| 429 as `.serverError(statusCode: 429, ...)` | `.tooManyRequests(response)` |
| `.unauthorized`, `.forbidden`, `.notFound` | `.unauthorized(response)`, `.forbidden(response)`, `.notFound(response)` |
| `.timeout` | `.timeout(nil)` for a transport timeout, `.timeout(response)` for a `408` |
| `.authorizationRefreshFailed` | `.authorizationRefreshFailed(underlying:)`, carrying your provider's error |
| `error.serverErrorData` | `error.response?.body` |
| `.invalidData` | removed (it could not occur) |

`catch NetworkError.unauthorized` without a binding still compiles. Build errors in tests as
`NetworkError.notFound(HTTPResponse(statusCode: 404))`.

- 4xx statuses other than 401, 403, 404, 408, and 429 are ``NetworkError/clientError(_:)``,
  not `serverError`. A non-2xx status outside 4xx and 5xx is
  ``NetworkError/unexpectedStatus(_:)``.
- **Behavior change:** cancelling the calling task always throws `CancellationError`. In 1.x,
  a cancel that landed while the request was on the wire came back as
  `NetworkError.underlying(URLError(.cancelled))`. Catch `CancellationError` instead.
- **Behavior change:** ``NetworkError/invalidResponse`` (a response that is not HTTP) is no
  longer transient, so ``MutationRetryPolicy`` stops retrying it.
- ``NetworkError/authorizationUnavailable(underlying:)`` is new; see the next section.
  Exhaustive switches over ``NetworkError`` and ``NetworkErrorClassification`` need it.
- ``NetworkErrorClassification/noInternetConnection`` replaces the 1.x `.noConnection` case,
  mirroring ``NetworkError/noInternetConnection``.
- ``NetworkErrorClassification`` also gained ``NetworkErrorClassification/clientError(statusCode:)``,
  ``NetworkErrorClassification/unexpectedStatus(statusCode:)``,
  ``NetworkErrorClassification/authorizationUnavailable``, and
  ``NetworkErrorClassification/serverUnreachable`` and
  ``NetworkErrorClassification/secureConnectionFailed``. To read a status code, use
  ``NetworkError/statusCode`` or `error.response?.statusCode`, not the classification.
- **Behavior change:** host lookup and connection-refused transport errors are now
  ``NetworkError/serverUnreachable(_:)`` and transient. `NetworkRetryPolicy` and
  `MutationRetryPolicy` can retry them; use ``NetworkError/category`` for user-facing decisions.
- `NetworkError.unauthorized()` with no argument is gone, because the case now carries the
  response. Build one with `NetworkError.unauthorized(HTTPResponse(statusCode: 401))`. This also
  applies to code written against the unreleased `feature/retry-and-mutation-failures` branch.
- To choose what to show the user, use the new ``NetworkError/category``
  (``NetworkErrorCategory``: `offline`, `serverUnreachable`, `timedOut`, `unauthorized`, `rateLimited`, `rejected`,
  `serverError`, `insecureConnection`, `other`) instead of keeping your own mapping.
  ``NetworkError/authorizationUnavailable(underlying:)`` is in `unauthorized`, with the `401` cases,
  because both mean the user must sign in again. Use ``NetworkError/classification`` to tell them apart.
  `429` is `rateLimited`, not `rejected`, because the same request can succeed later.
- **Behavior change:** a TLS failure, including a rejected certificate pin, is still
  ``NetworkError/underlying(_:)`` carrying the `URLError`, but its classification is now
  ``NetworkErrorClassification/secureConnectionFailed`` instead of `underlying`, and its category is
  `insecureConnection`.
- To map an error thrown outside the client, such as one from a stream returned by
  ``NetworkClient/sendAuthorized(_:operationName:errorBody:transport:)``, use ``NetworkError/mapTransportError(_:session:)``.
- **Behavior change:** decoding ``EmptyResponse`` ignores the body. In 1.x, a `2xx` with a body that
  was not JSON, such as `OK`, failed with `decodingFailed`, so ``NetworkClient/request(_:)`` and
  ``MutationQueue`` reported a failure for a request the server had applied.

```swift
switch error.category {
case .offline, .serverUnreachable, .timedOut: showOfflineBanner()
case .unauthorized: promptSignIn()
case .rateLimited: showTryAgainLater(after: error.retryAfter)
case .insecureConnection: showInsecureConnectionError()
case .rejected, .serverError, .other: showGenericError()
}
```

### Authorization

- `refreshAuthorizationIfNeeded() -> Bool` is gone, and
  ``AuthorizationProvider/refreshAuthorization(rejecting:)`` is now `async throws` instead of
  returning `Bool`. Implement it, and throw instead of returning `false`. The `rejected`
  argument lets you skip a refresh that another request already did.
- ``AuthorizationProvider/currentAuthorization()`` is `async throws`. Your non-throwing
  implementation still conforms. Throw when the user is signed out, and the client fails the
  request with ``NetworkError/authorizationUnavailable(underlying:)`` without sending it.
  **Source change:** calling it through `any AuthorizationProvider` or a generic `some AuthorizationProvider`
  now needs `try`. Calling it on your concrete non-throwing type does not.
- ``OAuthAuthorizationProvider``'s refresh handler is `() async throws -> String`. Throw
  instead of returning `nil`; the client surfaces the error as
  ``NetworkError/authorizationRefreshFailed(underlying:)``.
- ``AuthorizationProvider/shouldRefreshAuthorization(after:)`` lets a provider decide whether
  to refresh after a `401`, or after a provider-authorized `403`. The default refreshes `401`
  and declines `403`; override it when an API uses legacy `403` codes for expired tokens.
- ``AuthorizationType`` is no longer `Codable`.
- To skip a refresh that another request already did, call
  ``AuthorizationProvider/isCurrentAuthorization(_:)`` with `rejected` first.
- To send a request that ``NetworkClient`` cannot model, such as a Server-Sent Events stream,
  with the same authorization and refresh-once behavior, use
  ``NetworkClient/sendAuthorized(_:operationName:errorBody:transport:)`` instead of calling the provider yourself.
  Use it only for your own API; the provider's credentials are applied to any URL.
- An endpoint that must not carry the user's credentials, such as sign-in, token refresh, or a
  public endpoint, returns `false` from ``NetworkEndpoint/usesAuthorizationProvider``. In 1.x there
  was no way to opt out: `.none` always meant "use the provider". If your refresh handler calls the
  same client, its endpoint must opt out; ``OAuthAuthorizationProvider`` now fails a refresh requested
  from inside its own refresh with ``ReentrantRefreshError`` (also reachable as
  `OAuthAuthorizationProvider.ReentrantRefreshError`) instead of hanging.
- A custom provider that coalesced refreshes by hand can store an ``AuthorizationRefreshCoalescer`` and
  call ``AuthorizationRefreshCoalescer/refresh(rejecting:of:_:)`` from
  ``AuthorizationProvider/refreshAuthorization(rejecting:)``. It shares one refresh across requests that
  fail together, skips a stale rejection, and detects a nested refresh the same way
  ``OAuthAuthorizationProvider`` does. Use
  ``AuthorizationRefreshCoalescer/refresh(rejecting:isCurrentAuthorization:_:)`` when a changed
  authorization value does not necessarily mean a usable replacement exists, such as a provider
  that represents no token as ``AuthorizationType/none``.

#### Converting a `Bool` refresh

If your 1.x provider returned `true` when it refreshed and `false` when it could not,
move the failure into a thrown error:

```swift
// 1.x
func refreshAuthorizationIfNeeded() async -> Bool {
    guard let refreshToken = store.refreshToken else { return false }
    do {
        store.accessToken = try await service.refresh(refreshToken)
        return true
    } catch {
        return false
    }
}

// 2.0
struct SignedOut: Error {}

func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {
    guard await isCurrentAuthorization(rejected) else { return }
    guard let refreshToken = store.refreshToken else { throw SignedOut() }
    store.accessToken = try await service.refresh(refreshToken)
}
```

The client wraps whatever you throw in ``NetworkError/authorizationRefreshFailed(underlying:)``
and passes a `CancellationError` through unchanged. If you still need a `Bool` somewhere else,
catch the error at that call site, and let cancellation propagate:

```swift
func refreshSucceeded(rejecting rejected: AuthorizationType) async throws -> Bool {
    do {
        try await provider.refreshAuthorization(rejecting: rejected)
        return true
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        return false
    }
}
```

Prefer ``NetworkClient/sendAuthorized(_:operationName:errorBody:transport:)`` to hand-written wrappers like this one.

### Retries

- ``NetworkRetryPolicy`` is new and off by default. Set
  ``NetworkClientConfiguration/retryPolicy`` to retry idempotent requests.
  Its initializer takes a ``BackoffPolicy`` instead of separate delay settings:

```swift
// Unreleased feature branch
NetworkRetryPolicy(maxRetries: 3, baseDelay: .seconds(1), maxDelay: .seconds(30), maxRetryAfter: .seconds(60))
// 2.0
NetworkRetryPolicy(
    maxRetries: 3,
    backoff: BackoffPolicy(baseDelay: .seconds(1), maxDelay: .seconds(30), maxRetryAfter: .seconds(60))
)
```

- `GET`, `HEAD`, `PUT`, `DELETE`, and `OPTIONS` are idempotent by default. Other methods may
  opt in through ``NetworkEndpoint/isIdempotent`` only when the server guarantees replay safety.
  DNS and connection-refused errors now map to ``NetworkError/serverUnreachable(_:)`` and are
  considered transient alongside offline errors, timeouts, 429, and 5xx statuses.

- Both retry policies take a ``BackoffPolicy``:

```swift
// 1.x
MutationRetryPolicy(maxAttempts: 5, isRetryable: isRetryable)
// 2.0
MutationRetryPolicy(maxRetries: 5, shouldRetry: isRetryable)
```

- `delay(forAttempt:after:)` is `delay(forRetry:after:)`. The backoff settings moved into
  ``BackoffPolicy``: `policy.baseDelay`, `policy.maxDelay`, and `policy.jitterRange` are
  `policy.backoff.baseDelay`, `policy.backoff.maxDelay`, and `policy.backoff.jitterRange`.
  `maxAttempts` was renamed `maxRetries`; its meaning, retries after the first attempt, is
  unchanged.
- `MutationRetryPolicy.defaultIsRetryable(_:)` is
  ``MutationRetryPolicy/defaultShouldRetry(_:)``. The `isRetryable` property is gone: pass the
  predicate as `shouldRetry:` when creating the policy, and call
  ``MutationRetryPolicy/shouldRetry(_:)`` to evaluate it.

### Mutations

- ``MutationQueue`` requires a `client:`. It used to default to `NetworkClient.shared`, which
  has no authorization provider. Pass the client your app authenticates with.
- **Behavior change:** ``MutationRequest`` no longer stores authorization, and its
  ``MutationRequest/authorization`` is always ``AuthorizationType/none``. The queue's client
  authorizes every attempt through its ``AuthorizationProvider``, including a replay after
  relaunch. An endpoint's own authorization is dropped when you build a `MutationRequest`
  from it, so move static credentials into a provider. Remove `authorization:` from
  `MutationRequest(baseURL:path:method:...)` calls.
- The encoded `MutationRequest` carries a schema version. Payloads that a 1.x durable
  store saved still decode, and their persisted authorization is ignored.
- ``MutationKey`` conforms to `RawRepresentable` and encodes as a raw JSON string instead
  of a keyed container.
- ``MutationFailureReason`` has a ``MutationFailureReason/category`` (`offline`, `timedOut`,
  `serverUnreachable`, `unauthorized`, `rateLimited`, `rejected`, `serverError`, `insecureConnection`, `cancelled`,
  `other`) for choosing what to show.
- ``MutationStatus`` gained ``MutationStatus/waitingForConnectivity``, so exhaustive switches over it
  need the case. Only a queue created with `waitForConnectivity`
  (``MutationQueue/init(client:store:retryPolicy:waitForConnectivity:)``) reports it. Pass
  ``NetworkMonitor/waitUntilReachable()`` there when you use a durable ``MutationStore``, so an
  offline mutation waits for the network instead of being dropped after its retries.
- The ``MutationStatus/succeeded`` event carries the server's response in
  ``MutationQueue/MutationEvent/response``.
- ``MutationRequest/addingIdempotencyKey(_:header:)`` stores an idempotency key with the request, so
  every replay of a `POST` or `PATCH` sends the same one.
- ``MutationQueue/enqueueAndWait(_:key:)`` waits for the key's terminal outcome, returning its
  successful response or throwing its ``MutationFailureReason``. It subscribes before enqueueing,
  so callers no longer need to hand-roll an events subscription race.
- ``FileMutationStore`` provides built-in durable file persistence. Use an Application Support
  directory rather than the system caches directory, and choose file protection for sensitive
  request bodies. ``DiskCache`` is available for file-backed cache values; it is not encrypted.
- ``MutationRequest`` keeps an endpoint's ``NetworkEndpoint/usesAuthorizationProvider`` and encodes it.
  Payloads saved without it decode as `true`.

### Caching

``Cache`` stores whole ``CacheEntry`` values, a value plus the time it was stored, so a
reader can't pair a value with another write's timestamp.

- A custom cache implements four requirements:

```swift
actor DiskCache<Value: Sendable>: Cache {
    func entry(forKey key: CacheKey) async -> CacheEntry<Value>? { ... }
    func setEntry(_ entry: CacheEntry<Value>, forKey key: CacheKey) async { ... }
    func removeValue(forKey key: CacheKey) async { ... }
    func removeAll() async { ... }
}
```

  `value(forKey:)` and `setValue(_:forKey:)` come from a protocol extension; delete your
  implementations. Replace `timestamp(forKey:)` with `entry(forKey:)?.timestamp`, and
  `setValue(_:forKey:timestamp:)` with `setEntry(CacheEntry(value, timestamp: date), forKey:)`.
- `PersistentCache` and `TimestampedCache` are gone. Conform your disk cache to ``Cache``;
  <doc:CustomDiskCache> shows one that keeps the write time and the last-use time apart.
- `AnyCache(cache)` is gone. Use `any Cache<Value>`.
- `LocalDataSource` and `CacheBasedLocalDataSource` are gone. Pass the cache straight to the
  repository: `GenericRepository(client: client, cache: InMemoryCache<User>())`.
- ``LayeredCache`` has one initializer, `init(memoryCache:persistentCache:)`, whose persistent
  layer is optional.
- ``DiskCache`` is a built-in Codable file cache with optional byte and idle-time limits; use a
  custom ``Cache`` for database, encryption, or app-specific storage.
- ``CachePolicy`` also supports ``CachePolicy/reloadElseReturnCache`` and
  ``CachePolicy/returnCacheAndRevalidate(maxAge:)``. Exhaustive policy switches must handle them.
  ``Repository/fetchResult(using:cacheKey:policy:)`` returns a ``RepositoryResult`` with source
  and fetch timestamp; the existing ``Repository/fetch(using:cacheKey:policy:)`` still returns
  only the entity.
- ``SingleFlightCache`` accepts a `maxAge` when reading a cached value, so a long-lived entry
  can be refetched after its freshness window.
- `InMemoryCache.removeExpiredEntries(maxAge:)` is
  ``InMemoryCache/removeEntries(olderThan:)``.
- `CacheKey.user(id, resource: r)` is gone. Use `CacheKey(components: ["user", id, r])`,
  which produces the same key.

### Testing

- `MockAPIClient` implements `response(for:responseType:)`, and its `.http(HTTPResponse)`
  stub scripts response headers.
- `MutationRetryPolicy.immediate(maxAttempts:)` is `immediate(maxRetries:)`, and
  `NetworkRetryPolicy.immediate()` and `BackoffPolicy.immediate` are new.
