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
  `NetworkInstrumentationRecorder` from `SwiftyNetworkTesting` in tests.

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

### Authorization

- `refreshAuthorizationIfNeeded() -> Bool` is gone, and
  ``AuthorizationProvider/refreshAuthorization(rejecting:)`` is now `async throws` instead of
  returning `Bool`. Implement it, and throw instead of returning `false`. The `rejected`
  argument lets you skip a refresh that another request already did.
- ``AuthorizationProvider/currentAuthorization()`` is `async throws`. Your non-throwing
  implementation still conforms. Throw when the user is signed out, and the client fails the
  request with ``NetworkError/authorizationUnavailable(underlying:)`` without sending it.
- ``OAuthAuthorizationProvider``'s refresh handler is `() async throws -> String`. Throw
  instead of returning `nil`; the client surfaces the error as
  ``NetworkError/authorizationRefreshFailed(underlying:)``.
- ``AuthorizationProvider/shouldRefreshAuthorization(after:)`` is new (default `true`), so
  a provider can decline to refresh a `401` that a new token cannot fix.
- ``AuthorizationType`` is no longer `Codable`.

### Retries

- ``NetworkRetryPolicy`` is new and off by default. Set
  ``NetworkClientConfiguration/retryPolicy`` to retry idempotent requests.
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
- ``MutationFailureReason`` has a ``MutationFailureReason/category`` (`offline`, `timedOut`,
  `unauthorized`, `rejected`, `serverError`, `cancelled`, `other`) for choosing what to show.

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
- `PersistentCache` and `TimestampedCache` are gone. Conform your disk cache to ``Cache``.
- `AnyCache(cache)` is gone. Use `any Cache<Value>`.
- `LocalDataSource` and `CacheBasedLocalDataSource` are gone. Pass the cache straight to the
  repository: `GenericRepository(client: client, cache: InMemoryCache<User>())`.
- ``LayeredCache`` has one initializer, `init(memoryCache:persistentCache:)`, whose persistent
  layer is optional.
- `InMemoryCache.removeExpiredEntries(maxAge:)` is
  ``InMemoryCache/removeEntries(olderThan:)``.
- `CacheKey.user(id, resource: r)` is gone. Use `CacheKey(components: ["user", id, r])`,
  which produces the same key.

### Testing

- `MockAPIClient` implements `response(for:responseType:)`, and its `.http(HTTPResponse)`
  stub scripts response headers.
- `MutationRetryPolicy.immediate(maxAttempts:)` is `immediate(maxRetries:)`, and
  `NetworkRetryPolicy.immediate()` and `BackoffPolicy.immediate` are new.
