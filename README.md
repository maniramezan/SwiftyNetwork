# SwiftyNetwork

[![Build](https://img.shields.io/github/actions/workflow/status/maniramezan/SwiftyNetwork/build.yml?branch=main&label=build)](https://github.com/maniramezan/SwiftyNetwork/actions/workflows/build.yml)
[![Swift Versions](https://img.shields.io/endpoint?url=https://swiftpackageindex.com/api/packages/maniramezan/SwiftyNetwork/badge?type=swift-versions)](https://swiftpackageindex.com/maniramezan/SwiftyNetwork)
[![Platforms](https://img.shields.io/endpoint?url=https://swiftpackageindex.com/api/packages/maniramezan/SwiftyNetwork/badge?type=platforms)](https://swiftpackageindex.com/maniramezan/SwiftyNetwork)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

A modern, Swift-native networking library built with Swift 6 concurrency, providing a clean and type-safe API for network operations with built-in caching, authentication, and error handling.

## Features

- **Swift 6 Concurrency**: Built with async/await and actors for thread-safe operations
- **Type-Safe Endpoints**: Protocol-based endpoint definitions with compile-time safety
- **Flexible Caching**: Pluggable caching system with multiple policies
- **Disk Caching**: Optional file-backed `DiskCache` with byte and idle-time limits
- **Authentication Support**: Built-in OAuth and custom authentication providers
- **SSL Pinning**: Optional certificate and public-key pinning for controlled hosts
- **Safe Redirects**: Credentials are stripped from cross-origin redirects and HTTPS downgrades are refused
- **Comprehensive Error Handling**: Detailed error types with localized descriptions
- **Repository Pattern**: Clean separation between network and local data sources
- **Automatic Auth Refresh**: Refreshes credentials and replays the request once on `401`
- **Fire-and-Forget Mutations**: Background retry, key-based coalescing, and pluggable persistence via `MutationQueue`
- **Fetch Deduplication**: `SingleFlightCache` and `RemoteDataCache` share one fetch across concurrent callers
- **Reachability & Instrumentation**: `NetworkMonitor` streams reachability; `NetworkInstrumentation` exposes request timing and outcomes
- **Test Doubles**: The `SwiftyNetworkTesting` product ships `MockAPIClient` for unit tests and previews
- **Thread-Safe**: All operations are thread-safe using Swift's actor model

## Requirements

- Swift 6.2+
- iOS 18.0+ / macOS 15.0+

## Dependencies

SwiftyNetwork depends only on [SwiftCommons](https://github.com/maniramezan/SwiftCommons) for its
string, duration, logging, concurrency, and error helpers. It declares that dependency with `traits: []`, so
SwiftCommons' SwiftData-backed APIs are not pulled in on its behalf. SwiftCommons is imported internally and is
not part of SwiftyNetwork's API.

## Code Quality

This project uses [swift-format](https://github.com/swiftlang/swift-format) (Apple's official Swift formatter) for code formatting and linting.

### Local Development

Format code manually:

```bash
swift format format --in-place --recursive --parallel Sources Tests  # Format in-place
swift format lint --recursive --parallel Sources Tests                # Check for violations
```

### CI

swift-format runs in strict mode on all PRs (warnings treated as errors).
Configuration: `.swift-format`

CI also builds and tests with the minimum (6.2) and latest Swift toolchains, runs the suite on iOS
simulators, and checks pull requests for API breaking changes against the latest release.

## Installation

### Swift Package Manager

Add SwiftyNetwork to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/maniramezan/SwiftyNetwork.git", from: "2.0.0")
]
```

Or add it through Xcode: File → Add Package Dependencies → Enter the repository URL.

Upgrading from 1.x? See the [migration guide](https://maniramezan.github.io/SwiftyNetwork/documentation/swiftynetwork/migratingto2).

## Quick Start

### 1. Define an Endpoint

```swift
/// Example endpoint implementation for a REST API.
public struct UserEndpoint: NetworkEndpoint {
    public let baseURL: String
    public let userId: String
    
    public init(baseURL: String, userId: String) {
        self.baseURL = baseURL
        self.userId = userId
    }
    
    public var path: String {
        "/users/\(userId)"
    }
    
    public var method: HTTPMethod {
        .get
    }
    
    public var headers: [String : String]? {
        ["Accept": "application/json"]
    }
}
```

`HTTPMethod` predefines `GET`, `HEAD`, `POST`, `PUT`, `PATCH`, `DELETE`, and `OPTIONS`. Any other method is a
string literal away, for example `let method: HTTPMethod = "PROPFIND"`. `HTTPMethod` is a struct, so a `switch`
over it needs a `default` case.

When a group of endpoints shares a host and headers, keep `baseURL` required on `NetworkEndpoint` and provide
shared defaults through a protocol refinement. An endpoint can still override the host for a CDN or another service.
For a complete absolute URL returned by a server, use it as `baseURL` and leave `path` empty.

```swift
protocol ExampleAPIEndpoint: NetworkEndpoint {}

extension ExampleAPIEndpoint {
    var baseURL: String { "https://api.example.com" }
    var headers: [String: String]? { ["Accept": "application/json"] }
}

struct SettingsEndpoint: ExampleAPIEndpoint {
    let path = "/settings"
    let method: HTTPMethod = .get
}
```

### 2. Create a Data Model

```swift
/// Example user model.
public struct User: Codable, Sendable {
    public let id: String
    public let name: String
    public let email: String
    
    public init(id: String, name: String, email: String) {
        self.id = id
        self.name = name
        self.email = email
    }
}
```

### 3. Make a Network Request

```swift
// Simple network request
let client = NetworkClient.shared
let endpoint = UserEndpoint(baseURL: "https://api.example.com", userId: "123")

do {
    let user = try await client.request(endpoint, responseType: User.self)
    print("User: \(user.name)")
} catch {
    print("Error: \(error)")
}
```

## Advanced Usage

### Complete Repository Setup with Caching

```swift
/// Example function showing how to set up a complete repository with caching.
func createUserRepository() -> GenericRepository<User> {
    // Create network client with configuration
    let configuration = NetworkClientConfiguration(
        maxAuthRefreshAttempts: 3,
        timeout: .seconds(30)
    )
    let networkClient = NetworkClient(configuration: configuration)
    
    // Any Cache works: InMemoryCache, LayeredCache, or your own disk cache
    return GenericRepository(
        client: networkClient,
        cache: InMemoryCache<User>()
    )
}
```

### Unified APIClient Interface

`NetworkClient` conforms to `APIClient`, so you can accept any implementation in higher-level code:

```swift
func fetchUser(client: any APIClient, baseURL: String, userId: String) async throws -> User {
    let endpoint = UserEndpoint(baseURL: baseURL, userId: userId)
    return try await client.request(endpoint, responseType: User.self)
}
```

`APIClient` also sends `Encodable` JSON bodies, so code that only holds an `any APIClient` (and
`MockAPIClient` in tests) can post typed payloads. `NetworkClient` encodes them with its configured encoder:

```swift
let post = try await client.request(CreatePostEndpoint(), body: draft, responseType: Post.self)
```

### Per-Endpoint Options and Typed Endpoints

`NetworkEndpoint` can set a stable `operationName` for instrumentation, override the client timeout, choose a
`URLRequest` cache policy, and declare whether the request is idempotent. These defaults are per endpoint, so a
slow request or forced network refresh does not change unrelated calls:

```swift
struct BalanceEndpoint: TypedEndpoint {
    typealias Response = Balance

    let baseURL = "https://api.example.com"
    let path = "/balance"
    let method: HTTPMethod = .get
    var operationName: String? { "account.balance" }
    let timeout: Duration? = .seconds(20)
    let cachePolicy: URLRequest.CachePolicy? = .reloadIgnoringLocalCacheData
}

let balance = try await client.send(BalanceEndpoint())
```

`TypedEndpoint` binds the response type to the endpoint, removing repeated `responseType:` arguments. Its `send`
convenience also supports encoded bodies. Set `isIdempotent` to `true` only when the server guarantees that
replaying the request has no additional effect; this opts methods such as an idempotency-keyed `POST` into
`NetworkRetryPolicy`.

### Response Headers and Raw Bytes

`request(_:responseType:)` returns only the decoded value. When you also need the status code, headers, or raw
body of a successful response, call `response(for:responseType:)`. It returns a `DecodedResponse` holding
the `value` and its `HTTPResponse`, the same type that `NetworkError` carries for failures:

```swift
let page = try await client.response(for: PostsEndpoint(page: 1), responseType: [Post].self)
let posts = page.value
let nextPage = page.response.header("Link")
let etag = page.response.header("ETag")

let created = try await client.response(for: CreatePostEndpoint(), body: draft, responseType: EmptyResponse.self)
let location = created.response.header("Location")
```

Ask for `Data` to get the raw body without JSON decoding, for images, files, or a payload you decode yourself:

```swift
let avatar = try await client.request(AvatarEndpoint(userId: "42"), responseType: Data.self)
```

`response(for:responseType:)` is the one requirement an `APIClient` conformance implements; the `request`
methods are built on it.

### Built-in Disk Cache

`DiskCache` persists Codable values as individual files. It can bound total bytes and remove entries that have not
been used within a configured interval. Use a caches directory for evictable data; files are not encrypted.

```swift
let disk = DiskCache<User>(
    directory: URL.cachesDirectory.appending(path: "users", directoryHint: .isDirectory),
    maxBytes: 50_000_000,
    maxIdleTime: .seconds(7 * 86_400)
)
let cache = LayeredCache(memoryCache: InMemoryCache<User>(maxSize: 100), persistentCache: disk)
let repository = GenericRepository(client: NetworkClient.shared, cache: cache)
```

For pending mutations that must survive relaunches, use `FileMutationStore` under
`URL.applicationSupportDirectory`; unlike cache contents, pending work must not be stored in a reclaimable caches
directory. Both file-backed types store data as given, so choose appropriate file protection for sensitive data.

### Layered Caching with a Custom Persistent Cache

Implement `Cache` in your app when you need custom database or encryption behavior, then combine it with
the built-in in-memory cache using `LayeredCache`. A cache stores and returns whole `CacheEntry` values
(the value plus the time it was stored), so `LayeredCache` keeps the original timestamp when it promotes a
disk hit into memory, and a repository reads a value and its age in one call.

```swift
public actor UserDiskCache: Cache {
    // Replace this storage with file-backed I/O in your app.
    private var storage: [CacheKey: CacheEntry<User>] = [:]

    public init() {}

    public func entry(forKey key: CacheKey) async -> CacheEntry<User>? {
        storage[key]
    }

    public func setEntry(_ entry: CacheEntry<User>, forKey key: CacheKey) async {
        storage[key] = entry
    }

    public func removeValue(forKey key: CacheKey) async {
        storage.removeValue(forKey: key)
    }

    public func removeAll() async {
        storage.removeAll()
    }
}

func createLayeredRepository() -> GenericRepository<User> {
    let layeredCache = LayeredCache(memoryCache: InMemoryCache<User>(), persistentCache: UserDiskCache())
    return GenericRepository(client: NetworkClient.shared, cache: layeredCache)
}
```

`value(forKey:)` and `setValue(_:forKey:)` come for free from the protocol. Use `any Cache<User>` wherever
you need to store or pass a cache without naming its concrete type.

### Fetching with Different Cache Strategies

```swift
// Example 1: Cache-first strategy
func fetchUser(userId: String, baseURL: String) async throws -> User {
    let repository = createUserRepository()
    let endpoint = UserEndpoint(baseURL: baseURL, userId: userId)
    let cacheKey = CacheKey(components: ["user", userId, "profile"])
    
    // Fetch with cache fallback - tries cache first, then network
    return try await repository.fetch(
        using: endpoint,
        cacheKey: cacheKey,
        policy: .returnCacheElseLoad
    )
}

// Example 2: Force refresh from network
func refreshUser(userId: String, baseURL: String) async throws -> User {
    let repository = createUserRepository()
    let endpoint = UserEndpoint(baseURL: baseURL, userId: userId)
    let cacheKey = CacheKey(components: ["user", userId, "profile"])
    
    // Always fetch from network and update cache
    return try await repository.fetch(
        using: endpoint,
        cacheKey: cacheKey,
        policy: .reloadIgnoringCache
    )
}

// Example 3: Cache with expiration
func fetchUserWithExpiration(
    userId: String, 
    baseURL: String,
    maxCacheAge: Duration = .seconds(300)
) async throws -> User {
    let repository = createUserRepository()
    let endpoint = UserEndpoint(baseURL: baseURL, userId: userId)
    let cacheKey = CacheKey(components: ["user", userId, "profile"])
    
    // Use cached data if not older than maxCacheAge, otherwise fetch from network
    return try await repository.fetch(
        using: endpoint,
        cacheKey: cacheKey,
        policy: .returnCacheIfNotExpired(maxAge: maxCacheAge)
    )
}
```

`reloadElseReturnCache` is useful when the network should be tried first but saved data must remain available if
the request fails. `returnCacheAndRevalidate(maxAge:)` returns cached data immediately and refreshes stale data in
the background. Use `fetchResult` when the caller needs to know whether the value came from the network or cache,
or how old it is:

```swift
let result = try await repository.fetchResult(
    using: UserEndpoint(baseURL: baseURL, userId: userId),
    cacheKey: cacheKey,
    policy: .reloadElseReturnCache
)
show(result.value, isSaved: result.source == .cache, age: result.age())
```

### OAuth Authentication

```swift
/// Example showing OAuth authentication setup.
func createAuthenticatedClient(accessToken: String) -> NetworkClient {
    let authProvider = OAuthAuthorizationProvider(initialAccessToken: accessToken) {
        // Exchange your refresh token for a new access token, or throw.
        // The client surfaces the error as NetworkError.authorizationRefreshFailed(underlying:).
        try await tokenService.refreshAccessToken()
    }
    
    let configuration = NetworkClientConfiguration(
        authorizationProvider: authProvider,
        maxAuthRefreshAttempts: 2
    )
    
    return NetworkClient(configuration: configuration)
}

// Usage
let authenticatedClient = createAuthenticatedClient(accessToken: "your-access-token")
let endpoint = UserEndpoint(baseURL: "https://api.example.com", userId: "123")

do {
    let user = try await authenticatedClient.request(endpoint, responseType: User.self)
    print("Authenticated request successful: \(user.name)")
} catch {
    print("Error: \(error)")
}
```

`OAuthAuthorizationProvider` coalesces concurrent refreshes, and a `401` for a token that another request
already replaced retries with the new token instead of refreshing again. That matters for servers that
rotate refresh tokens. Call `updateAccessToken(_:)` after sign-in to swap the token without rebuilding the
client. Custom providers implement `refreshAuthorization(rejecting:)`: return when newer credentials are
available, or throw, and the client reports `NetworkError.authorizationRefreshFailed(underlying:)` with your error.

`currentAuthorization()` can throw too, for example when the user is signed out or a proactive refresh of
an expiring token failed. The client then fails the request with
`NetworkError.authorizationUnavailable(underlying:)` carrying your error and never sends it. A provider that
cannot fail can keep a non-throwing `currentAuthorization()`:

```swift
actor SessionAuthorizationProvider: AuthorizationProvider {
    struct SignedOut: Error {}
    private var token: String?

    func currentAuthorization() async throws -> AuthorizationType {
        guard let token else { throw SignedOut() }
        return .bearer(token: token)
    }

    func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {
        // Refresh `token`, or throw.
    }
}
```

A provider can also decide whether a refresh is useful by implementing `shouldRefreshAuthorization(after:)`. The
client passes it a `401` response, or a `403` response to a request the provider authorized. Return `false` when a
new token cannot fix the failure. The default refreshes `401` and does not refresh `403`; an API that uses legacy
`403` codes for expired tokens can opt in by inspecting the response body or headers.

Inside `refreshAuthorization(rejecting:)`, `guard await isCurrentAuthorization(rejected) else { return }` skips a
refresh that another request already did.

#### Endpoints without the user's credentials

An endpoint whose `authorization` is `.none` gets the provider's credentials. Return `false` from
`usesAuthorizationProvider` for sign-in, sign-up, token refresh, public endpoints, and other services' URLs. The
request then carries only the endpoint's own `authorization`, and a `401` throws `unauthorized` without a refresh:

```swift
struct RefreshTokenEndpoint: NetworkEndpoint {
    let baseURL = "https://api.example.com"
    let path = "/oauth/token"
    let method: HTTPMethod = .post
    var usesAuthorizationProvider: Bool { false }
}
```

If the refresh handler calls the same client, its endpoint must opt out. Otherwise it carries the expired token, and a
`401` from it would ask the provider to refresh from inside its own refresh. `OAuthAuthorizationProvider` fails that
nested refresh with `ReentrantRefreshError` rather than waiting on itself.

### Streaming and Other Transports

`NetworkClient` decodes whole responses, so it cannot carry a Server-Sent Events stream. `sendAuthorized` runs a raw
`URLRequest` through a transport you supply, with the client's authorization, `401` refresh-once, redirect policy, and
instrumentation, and throws the same `NetworkError` cases:

```swift
let (bytes, _) = try await client.sendAuthorized(request) { request, session, delegate in
    try await session.bytes(for: request, delegate: delegate)
} errorBody: { bytes in
    var body = Data()
    do { for try await byte in bytes { body.append(byte) } } catch {}
    return body
}
do {
    for try await line in bytes.lines {
        handle(line)
    }
} catch {
    // The client's work ends at the response headers; map stream errors the same way it does.
    throw NetworkError.mapTransportError(error)
}
```

It returns only for a `2xx`. It never retries transient failures and does not set a timeout. Instrumentation reports
the attempt as completed when the headers arrive. Use it only for your own API: the provider's credentials go to
any URL, so call `URLSession` directly for presigned or third-party URLs, and map its errors with
`NetworkError.mapTransportError(_:session:)`. Background sessions are not supported.

### Fire-and-Forget Mutations with MutationQueue

Use `MutationQueue` for "forgivable" mutations -- liking a post, updating a setting -- that
shouldn't block the UI on the network round trip and shouldn't be silently lost to a transient
failure. `NetworkClient` doesn't retry transient/5xx errors unless you opt in (see
[Retrying Idempotent Requests](#retrying-idempotent-requests)); `MutationQueue`
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

When the caller needs the result, `enqueueAndWait` returns the response (or throws a `MutationFailureReason`)
while retaining queue retry and coalescing behavior:

```swift
let response = try await queue.enqueueAndWait(request, key: "like:video:42")
```

Mutations for different keys run independently and may finish in any order, so enqueue one that depends on
another only after the first succeeds. The `.succeeded` event carries the server's response, for example the
identifier of a created record:

```swift
if event.status == .succeeded, let post = try? event.response?.decodeBody(Post.self) {
    store.replaceDraft(id: event.key, with: post)
}
```

The queue replays `POST` and `PATCH` after a timeout or a 5xx, when the server may already have applied them. If your
API supports idempotency keys, send one; it is stored with the request, so every replay sends the same key:

```swift
let request = try MutationRequest(endpoint: CreatePostEndpoint(), encodableBody: draft).addingIdempotencyKey()
```

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
| `.other` | Encoding, decoding, invalid URL, or a non-`NetworkError` | Generic error |

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

Persistence is pluggable via the `MutationStore` protocol. `InMemoryMutationStore` ships as the
default; mutations are lost if the process is killed. `FileMutationStore` persists pending requests
so they can be replayed after relaunch:
Because `MutationRequest` is `Codable`, a durable store can serialize "which endpoint plus what
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

A `MutationRequest` never captures credentials: its `authorization` is always `.none`, so every attempt,
including a replay after relaunch, is authorized by the client's `AuthorizationProvider`, and a `401`
refreshes the token instead of replaying a stale one. An endpoint's own `authorization` is dropped (with a
logged warning) when you build a `MutationRequest` from it.

> **Note:** Headers and bodies are persisted as given. Keep secrets out of them, and store durable
> mutations securely anyway, since bodies can contain user data.

### SSL Pinning

Use SSL pinning when your app and API are operated together and you can safely rotate pins before server
certificates or keys change. Pinning is enforced only for configured hosts; all other hosts use normal
`URLSession` trust handling.

```swift
enum PinConfigurationError: Error {
    case invalidPin
}

func makePinnedClient() throws -> NetworkClient {
    guard let apiPublicKeyPin = SSLPinningConfiguration.Pin.publicKeySHA256(
        base64Encoded: "BASE64_ENCODED_SHA256_PUBLIC_KEY_HASH"
    ) else {
        throw PinConfigurationError.invalidPin
    }

    let pinning = SSLPinningConfiguration(
        pinnedHosts: [
            "api.example.com": [apiPublicKeyPin]
        ],
        includesSubdomains: false,
        requiresDefaultTrustValidation: true
    )

    let configuration = NetworkClientConfiguration(
        session: pinning.makeSession(),
        timeout: .seconds(30)
    )
    return NetworkClient(configuration: configuration)
}
```

Public-key pins use the industry-standard SPKI SHA-256 format (the same format as HPKP and TrustKit).
Generate one for a live server with:

```bash
openssl s_client -connect api.example.com:443 < /dev/null 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary \
  | base64
```

For certificate pins, use `.certificate(_:)` with DER certificate data or `.certificateSHA256(base64Encoded:)`.
For safer rotations, configure more than one accepted pin during certificate or key rollovers.

### Redirects

`NetworkClient` checks every redirect against `NetworkClientConfiguration.redirectPolicy` before
`URLSession` follows it. The default, `.stripCredentialsAcrossOrigins`, does what `curl` and browser `fetch` do:

- A redirect within the same origin (scheme, host, and port) is followed unchanged.
- A redirect to another origin is followed without the `Authorization`, `Proxy-Authorization`, and `Cookie`
  headers, or the header an `.apiKey` or `.custom` authorization set.
- A redirect from `https` to plain `http` is refused.

A refused redirect throws `NetworkError.unexpectedStatus` with the `3xx` response, so you can read its
`Location` header. Use `.never` for an API that should not redirect at all, or `.followAll` to let `URLSession`
follow every redirect with its headers, as 1.x did:

```swift
let configuration = NetworkClientConfiguration(redirectPolicy: .never)
```

Your own redirect handling always wins. If the session you inject has a delegate that implements
`urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`, `NetworkClient` hands every redirect
to it and uses its answer unchanged, under any policy, so that delegate must remove credentials itself. A
session delegate that doesn't handle redirects, such as the TLS pinning one, leaves them to the policy.

Credentials sent under another header name through an endpoint's `headers` are not recognized; send them
through an `AuthorizationType` so they are stripped.

### Deduplicating Fetches with SingleFlightCache and RemoteDataCache

`SingleFlightCache` wraps any `Cache` so concurrent misses for the same key share one fetch.
`RemoteDataCache` builds on it to cache raw response bytes (for example images) by URL.

```swift
let users = SingleFlightCache(InMemoryCache<User>(maxSize: 500))
// Ten concurrent callers trigger one network request.
let user = try await users.value(forKey: "user:42") {
    try await client.request(UserEndpoint(baseURL: baseURL, userId: "42"), responseType: User.self)
}

// Set maxAge to replace entries older than the freshness window.
let profiles = SingleFlightCache(InMemoryCache<Profile>(maxSize: 500))
let freshProfile = try await profiles.value(forKey: "profile:42", maxAge: .seconds(300)) {
    try await client.request(ProfileEndpoint(userId: "42"), responseType: Profile.self)
}

let images = RemoteDataCache(cache: InMemoryCache<Data>(maxSize: 200))
let avatar = try await images.data(for: avatarURL)
```

`RemoteDataCache` keys only by URL. Use a separate instance per account for authenticated content.

### Reachability with NetworkMonitor

```swift
let monitor = NetworkMonitor.shared
await monitor.startMonitoring()

for await status in await monitor.updates {
    offlineBanner.isHidden = status == .reachable
}
```

Each `updates` stream starts with the current status and only keeps the latest value for slow consumers.

### Request Instrumentation

Conform to `NetworkInstrumentation` to feed request timing and outcomes into your observability stack.
Every method has a no-op default, so implement only what you need.

```swift
struct RequestMetrics: NetworkInstrumentation {
    func requestCompleted(_ event: NetworkRequestCompletion) async {
        Metrics.record("http.duration_ms", event.duration / .milliseconds(1), tags: ["status": "\(event.statusCode)"])
    }

    func requestFailed(_ event: NetworkRequestFailure) async {
        Metrics.increment("http.failure", tags: ["category": "\(event.error.classification)"])
    }
}

let client = NetworkClient(configuration: NetworkClientConfiguration(instrumentation: RequestMetrics()))
```

Set `operationName` on an endpoint to attach a stable, low-cardinality operation name to every attempt,
completion, and failure event. Events also include full URLs and errors; redact them before exporting and prefer
the operation name over URL labels.

### Custom Cache Implementation

For a database-backed or otherwise custom cache, see the `CustomDiskCache` DocC article. For ordinary file-backed
storage, use the built-in `DiskCache`.

```swift
// Implement custom cache
public actor MyCustomCache<T: Sendable>: Cache {
    // Your custom cache implementation here
    public func entry(forKey key: CacheKey) async -> CacheEntry<T>? { /* ... */ }
    public func setEntry(_ entry: CacheEntry<T>, forKey key: CacheKey) async { /* ... */ }
    public func removeValue(forKey key: CacheKey) async { /* ... */ }
    public func removeAll() async { /* ... */ }
}

// Use with repository
let repository = GenericRepository(client: NetworkClient.shared, cache: MyCustomCache<User>())
```

## Cache Policies

SwiftyNetwork supports five repository caching strategies:

- **`.returnCacheElseLoad`**: Return cached data if available, otherwise fetch from network
- **`.reloadIgnoringCache`**: Always fetch from network and update cache
- **`.returnCacheIfNotExpired(maxAge:)`**: Use cached data if not older than specified age
- **`.reloadElseReturnCache`**: Fetch first; return cached data if that request fails
- **`.returnCacheAndRevalidate(maxAge:)`**: Return cached data immediately and refresh stale data in the background

## Error Handling

Every failure is a `NetworkError`. HTTP statuses each get their own case, so a rejected request (4xx),
a failing server (5xx), and a device that is offline never look alike:

| Case | When |
| --- | --- |
| `unauthorized`, `forbidden`, `notFound`, `tooManyRequests` | `401`, `403`, `404`, `429` |
| `clientError` | Any other `4xx`, such as `400`, `409`, or `422` |
| `serverError` | Any `5xx` |
| `unexpectedStatus` | A non-2xx status outside 4xx and 5xx, such as a `3xx` the redirect policy refused |
| `timeout` | A `408`, or a transport timeout (no response) |
| `noInternetConnection` | The device is offline or the connection dropped |
| `serverUnreachable` | DNS could not resolve the host or the server refused the connection |

```swift
do {
    let user = try await client.request(endpoint, responseType: User.self)
} catch NetworkError.unauthorized {
    // Handle authentication error
} catch NetworkError.clientError(let response) {
    // The server rejected the request, for example a validation error
} catch NetworkError.serverError(let response) {
    // Handle server error with response.statusCode
} catch NetworkError.noInternetConnection {
    // Offline
} catch NetworkError.decodingFailed(let underlying) {
    // Handle JSON decoding error
} catch {
    // Handle other errors
}
```

Every HTTP case carries the rejected `HTTPResponse` (only a transport `timeout` has none). Read its
status, headers, and body to tell apart failures that share a status code, such as an API error `code` in
the body, the `WWW-Authenticate` challenge, or `X-RateLimit-*` headers. `error.response` and
`error.statusCode` give the same values without a `switch`:

```swift
struct APIErrorBody: Decodable { let code: String }

do {
    let user = try await client.request(endpoint, responseType: User.self)
} catch NetworkError.forbidden(let response) {
    let apiError = try? response.decodeBody(APIErrorBody.self)
    if apiError?.code == "registration_required" {
        showRegistration()
    }
} catch NetworkError.unauthorized(let response) {
    let challenge = response.wwwAuthenticate
}
```

`catch NetworkError.unauthorized` without a binding still matches. Construct these errors in test doubles
as `NetworkError.notFound(HTTPResponse(statusCode: 404))`. The body is raw server data and
may contain user information, so don't log it. `HTTPResponse` prints only its status code, header names,
and body size, so interpolating it, or an error that carries it, into a log line doesn't leak header values or body.

Use `NetworkError.isTransient` (or `classification` for telemetry tags) to decide whether a retry could help.
Timeouts, lost connectivity, unreachable hosts, `429`, and 5xx statuses count as transient. This is the same rule
`NetworkRetryPolicy` and `MutationRetryPolicy.default` use.

Cancelling the calling task always surfaces as `CancellationError`, whether it lands while the request is on
the wire, during a retry wait, or during an auth refresh. It is never wrapped in a `NetworkError`:

```swift
do {
    let user = try await client.request(endpoint, responseType: User.self)
} catch is CancellationError {
    // The view went away; nothing to show
}
```

### Choosing What to Show

`error.category` collapses the cases into what a UI treats differently, the same grouping as
`MutationFailureReason.category`. `authorizationUnavailable` counts as `unauthorized`; use `error.classification`
to tell it apart from a `401`.

```swift
switch error.category {
case .offline, .serverUnreachable, .timedOut: showOfflineBanner()
case .unauthorized: promptSignIn()
case .rateLimited: showTryAgainLater(after: error.retryAfter)
case .insecureConnection: showInsecureConnectionError()
case .rejected, .serverError, .other: showGenericError()
}
```

`.insecureConnection` covers an untrusted certificate, a failed TLS handshake, and a rejected certificate pin, which
`URLSession` reports as `URLError.cancelled`.

### Rate Limiting (429) and Retry-After

A `429 Too Many Requests` response is reported as `NetworkError.tooManyRequests(_:)`, never as
`.clientError`. `HTTPResponse.retryAfter` is the parsed `Retry-After` header as a `Duration` (both the
delta-seconds and HTTP-date forms; `nil` if absent or malformed), `body` keeps the response body (empty if the
server sent none) so you can decode a problem+json document, and the headers keep values such as
`X-RateLimit-Remaining`. A `503 Service Unavailable` carries `retryAfter` on `.serverError` the same way:

```swift
do {
    _ = try await client.request(endpoint, responseType: User.self)
} catch NetworkError.tooManyRequests(let response) {
    let throttle = try? response.decodeBody(Problem.self)
    showBanner("Slow down", retryIn: response.retryAfter)
}
```

`error.retryAfter` gives the same value without a `switch`.

### Retrying Idempotent Requests

`NetworkClient` never retries transient failures by default. Opt in with a `NetworkRetryPolicy`:

```swift
let configuration = NetworkClientConfiguration(
    retryPolicy: NetworkRetryPolicy(
        maxRetries: 2,
        backoff: BackoffPolicy(baseDelay: .milliseconds(500), maxDelay: .seconds(8), maxRetryAfter: .seconds(30))
    )
)
let client = NetworkClient(configuration: configuration)
```

- `GET`, `HEAD`, `PUT`, `DELETE`, and `OPTIONS` are idempotent by default. `POST`, `PATCH`, and custom methods are not.
  An endpoint may opt an operation such as a server-deduplicated sync `POST` into retries with `isIdempotent`.
- Retried failures: `429`, 5xx, timeouts, lost connectivity, and unreachable hosts. Other 4xx responses and decoding failures
  are reported immediately.
- Waits follow a `BackoffPolicy`: exponential with jitter, capped at `maxDelay`. A `429` or `503` `Retry-After` is
  honored (the wait is at least that long) and clamped to `maxRetryAfter`, so a huge value can't park a request.
- Waits are cancellation-aware: cancelling the calling task ends the wait with `CancellationError`.
- `maxRetries` bounds the retries after the first attempt, independently of `maxAuthRefreshAttempts`.
  Each retry emits `requestRetried` to your `NetworkInstrumentation`.

If the client sits behind a `MutationQueue`, its `MutationRetryPolicy` also retries; enabling both makes
the attempts multiply, so prefer one. Both policies have the same shape: `maxRetries` counts retries after the
first attempt, `backoff` is a `BackoffPolicy`, and `shouldRetry` decides which failures are retried.
`MutationRetryPolicy.defaultBackoff` honors `Retry-After` up to 300s, so a throttled mutation waits as long as the
server asked instead of failing.

## Configuration

### Network Client Configuration

```swift
let configuration = NetworkClientConfiguration(
    session: URLSession.shared,
    decoder: JSONDecoder(),
    encoder: JSONEncoder(),
    authorizationProvider: authProvider,
    maxAuthRefreshAttempts: 3,
    retryPolicy: nil,
    redirectPolicy: .stripCredentialsAcrossOrigins,
    timeout: .seconds(30)
)

let client = NetworkClient(configuration: configuration)
```

A client keeps its configuration for its lifetime; create a new client to change it.

## Versioning

SwiftyNetwork follows [Semantic Versioning](https://semver.org). The public enums (`NetworkError`,
`NetworkErrorClassification`, `AuthorizationType`, `CachePolicy`, `MutationStatus`,
`MutationFailureReason.Category`, `NetworkReachability`, and `LogLevel`) gain new cases only in a major
release, so an exhaustive `switch` over them keeps compiling across minor and patch releases. Types meant to
grow, such as `HTTPMethod` and `RedirectPolicy`, are structs, so their new values can arrive in any release.

### Logging

SwiftyNetwork logs through `os.Logger` under the `SwiftyNetwork` subsystem at `.warning` by default. The level is
package-wide, so set it once at launch rather than per client:

```swift
LogLevel.current = .debug
```

### Custom JSON Decoding

```swift
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
decoder.keyDecodingStrategy = .convertFromSnakeCase

let configuration = NetworkClientConfiguration(decoder: decoder)
```

## Architecture

SwiftyNetwork is built around several key protocols and types:

- **`NetworkEndpoint`**: Defines API endpoints
- **`APIClient`**: Abstract network request interface
- **`Cache`**: Generic caching interface storing `CacheEntry` values (value + timestamp)
- **`Repository`**: Combines a network client and a cache
- **`AuthorizationProvider`**: Handles authentication
- **`SSLPinningConfiguration`**: Configures certificate and public-key pinning
- **`RedirectPolicy`**: Decides how redirects are followed and when credentials are stripped
- **`MutationQueue`**: Fire-and-forget mutations with background retry and coalescing
- **`MutationStore`**: Pluggable persistence for pending mutations

This design promotes clean separation of concerns, testability, and flexibility.

## Thread Safety

All operations in SwiftyNetwork are thread-safe:

- Network clients use Swift actors for thread-safe state management
- Caches are implemented as actors
- All protocols are marked as `Sendable`

## Testing

Link `SwiftyNetwork` from your app or library target and `SwiftyNetworkTesting` only from its
**test target**. `SwiftyNetworkTesting` already depends on `SwiftyNetwork`, so do not add the core
product to the test target again; this keeps Swift Package Manager's dependency graph to one copy
of `SwiftyNetwork`.

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

This makes `MockAPIClient` and `TestAuthorizationProvider` available to the test target.

```swift
import SwiftyNetwork
import SwiftyNetworkTesting
import Testing

@Test func likeRetriesTransientFailures() async throws {
    let client = MockAPIClient()
    // The first call times out, then every later call succeeds.
    await client.stub(.post, "/likes", with: .failure(NetworkError.timeout(nil)), .empty)

    let queue = MutationQueue(client: client, retryPolicy: .immediate())
    await queue.enqueue(MutationRequest(endpoint: LikeVideoEndpoint(videoID: "42")), key: "like:video:42")
    // ... await a `.succeeded` event from `queue.events()`

    let sent = await client.requests(to: "/likes")
    #expect(sent.count == 2)
}

@Test func repositoryCachesUsers() async throws {
    let client = MockAPIClient()
    try await client.stub(.get, "/users/123", returning: User(id: "123", name: "Ada", email: "ada@example.com"))
    let repository = GenericRepository(client: client, cache: InMemoryCache<User>())
    // ...
}
```

`TestAuthorizationProvider` is a scriptable `AuthorizationProvider` for the same targets: a fixed bearer token, a
`refreshCallCount`, the `rejectedAuthorizations`, and `setRefreshResult(_:)` to change the refresh outcome mid-test.
Like the rest of `SwiftyNetworkTesting`, it is for test targets and previews only.

Stub `.http(HTTPResponse(statusCode: 200, headers: ["ETag": "v2"], body: data))` to script response headers
for code that reads `response(for:responseType:)`. Responses for a route are consumed in order and the last one repeats. Unstubbed routes throw
`MockAPIClient.UnstubbedRequestError` unless you set a fallback with `setFallback(_:)`.

## Contributing

We welcome contributions! Please read our [CONTRIBUTING.md](CONTRIBUTING.md) guidelines and submit pull requests to our GitHub repository.

### Running Tests

```bash
# Run all tests
swift test

# Run tests with coverage
swift test --enable-code-coverage

# Generate coverage report
xcrun llvm-cov report .build/debug/SwiftyNetworkPackageTests.xctest/Contents/MacOS/SwiftyNetworkPackageTests \
  -instr-profile .build/debug/codecov/default.profdata
```

The test suite covers caching, networking, auth, SSL pinning, and repository flows.

## License

SwiftyNetwork is available under the MIT license. See the [LICENSE](LICENSE) file for more info.

## Support

- **Documentation**: Full API documentation is published via GitHub Pages
- **Live docs**: [https://maniramezan.github.io/SwiftyNetwork](https://maniramezan.github.io/SwiftyNetwork)
- **Issues**: [GitHub Issues](https://github.com/maniramezan/SwiftyNetwork/issues)
- **Discussions**: [GitHub Discussions](https://github.com/maniramezan/SwiftyNetwork/discussions)

## GraphQL

See [the GraphQL guide](GRAPHQL.md) for typed variables, response envelopes,
partial results, and transport limitations. GraphQL uses the existing HTTP
pipeline; no schema compiler or additional dependency is required.

## Architecture and review

[ARCHITECTURE.md](ARCHITECTURE.md) describes the current implementation and
[REVIEW.md](REVIEW.md) records remaining correctness and performance work.
