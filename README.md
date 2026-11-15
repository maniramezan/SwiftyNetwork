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
- **Test Doubles**: `@_spi(Testing) import SwiftyNetwork` gives tests and previews `MockAPIClient` and `TestAuthorizationProvider`
- **Thread-Safe**: All operations are thread-safe using Swift's actor model

## Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Advanced Usage](#advanced-usage): repositories and caching, authentication, streaming, mutations, SSL pinning,
  redirects, reachability, instrumentation
- [Full guides and API reference](https://maniramezan.github.io/SwiftyNetwork)
- [Cache Policies](#cache-policies)
- [Error Handling](#error-handling)
- [Configuration](#configuration): client options, logging, JSON decoding
- [Versioning](#versioning)
- [Testing](#testing)
- [GraphQL](#graphql)
- [Contributing](#contributing)

## Requirements

- Swift 6.2+
- iOS 18.0+ / macOS 15.0+

## Dependencies

SwiftyNetwork depends only on [SwiftCommons](https://github.com/maniramezan/SwiftCommons) for its
string, duration, logging, concurrency, and error helpers. It declares that dependency with `traits: []`, so
SwiftCommons' SwiftData-backed APIs are not pulled in on its behalf. SwiftCommons is imported internally and is
not part of SwiftyNetwork's API.

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
been used within a configured interval. Different keys are read and written in parallel, four operations at a time
by default; pass `maxConcurrentOperations:` to change the limit. Use a caches directory for evictable data; files are not encrypted.

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

For a complete file-backed example, see the `CustomDiskCache` DocC article. For ordinary file-backed storage, use
the built-in `DiskCache`.

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

A custom provider gets the same coalescing as `OAuthAuthorizationProvider` from `AuthorizationRefreshCoalescer`.
Requests that fail together share one refresh, a `401` for a credential that was already replaced skips the refresh,
and an app-initiated refresh runs after any refresh already in flight, so its credential reflects state as of the call:

```swift
actor SessionAuthorizationProvider: AuthorizationProvider {
    private let refreshes = AuthorizationRefreshCoalescer()
    private var token: String

    func currentAuthorization() async -> AuthorizationType { .bearer(token: token) }

    func refreshAuthorization(rejecting rejected: AuthorizationType) async throws {
        try await refreshes.refresh(rejecting: rejected, of: self) {
            let newToken = try await sessionService.reauthenticate()
            await self.store(newToken)
        }
    }

    func forceRefresh() async throws {
        try await refreshes.refresh {
            let newToken = try await sessionService.reauthenticate()
            await self.store(newToken)
        }
    }

    private func store(_ newToken: String) { token = newToken }
}
```

The refresh closure must store the new credential before it returns. `isCurrentAuthorization(_:)` alone skips a
refresh that another request already finished, but it does not stop requests that fail together from each refreshing.

`refresh(rejecting:of:_:)` treats a thrown `currentAuthorization()` as "refresh" and any different value as "already
replaced, skip". A provider that reports "no usable credential" as a value (for example `.none`, because throwing would
turn a transient failure into a sign-in prompt) would skip a refresh that is still needed. Pass the staleness check
yourself instead; return `true` while the rejected credential still needs replacing:

```swift
try await refreshes.refresh(
    rejecting: rejected,
    isCurrentAuthorization: {
        let current = await self.currentAuthorization()
        return current == .none || current == rejected
    }
) {
    let newToken = try await sessionService.reauthenticate()
    await self.store(newToken)
}
```

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
`401` from it would ask the provider to refresh from inside its own refresh. `AuthorizationRefreshCoalescer`, and so
`OAuthAuthorizationProvider`, fails that nested refresh with `ReentrantRefreshError` rather than waiting on itself.

### Streaming and Other Transports

`NetworkClient` decodes whole responses. For Server-Sent Events and other transports it cannot model, `sendAuthorized`
runs a raw `URLRequest` through a transport you supply, with the client's authorization, `401` refresh-once, redirect
policy, and instrumentation:

```swift
let (bytes, _) = try await client.sendAuthorized(request) { request, session, delegate in
    try await session.bytes(for: request, delegate: delegate)
}
```

See [Streaming responses](https://maniramezan.github.io/SwiftyNetwork/documentation/swiftynetwork/streamingresponses) for error bodies, stream error mapping, and its limits.

### Fire-and-Forget Mutations with MutationQueue

Use `MutationQueue` for mutations that shouldn't block the UI or be lost to a transient failure, such as liking a
post. It retries with backoff (including non-idempotent requests), coalesces by key, reports status, and can persist
pending work across launches:

```swift
let directory = URL.applicationSupportDirectory.appending(path: "PendingMutations", directoryHint: .isDirectory)
let queue = MutationQueue(client: authenticatedClient, store: FileMutationStore(directory: directory)) {
    await NetworkMonitor.shared.waitUntilReachable()
}
await queue.resumePendingMutations() // call once at startup

// Returns immediately; a later enqueue for the same key replaces this one.
await queue.enqueue(MutationRequest(endpoint: LikeVideoEndpoint(videoID: "42")), key: "like:video:42")

// Or wait for the outcome while keeping the queue's retries and coalescing.
let response = try await queue.enqueueAndWait(request, key: "like:video:42")
```

A `MutationRequest` never captures credentials; the queue's client authorizes every attempt. Headers and bodies are
persisted as given, so keep secrets out of them. See [Queueing mutations offline](https://maniramezan.github.io/SwiftyNetwork/documentation/swiftynetwork/offlinemutations) for
status events, failure categories, idempotency keys, and persistence.

### SSL Pinning and Redirects

Pin certificates or public keys for hosts you operate by passing a pinned session to the client. Hosts you don't list
use normal `URLSession` trust handling:

```swift
let pinning = SSLPinningConfiguration(pinnedHosts: ["api.example.com": [apiPublicKeyPin]])
let client = NetworkClient(configuration: NetworkClientConfiguration(session: pinning.makeSession()))
```

Redirects follow `NetworkClientConfiguration.redirectPolicy`. The default, `.stripCredentialsAcrossOrigins`, removes
credentials from a redirect to another origin and refuses an `https` to `http` downgrade; `.never` and `.followAll`
are the alternatives. See [Securing connections](https://maniramezan.github.io/SwiftyNetwork/documentation/swiftynetwork/securingconnections) for generating pins, rotation, and how
session delegates interact with the policy.

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

## Cache Policies

SwiftyNetwork supports five repository caching strategies:

- **`.returnCacheElseLoad`**: Return cached data if available, otherwise fetch from network
- **`.reloadIgnoringCache`**: Always fetch from network and update cache
- **`.returnCacheIfNotExpired(maxAge:)`**: Use cached data if not older than specified age
- **`.reloadElseReturnCache`**: Fetch first; return cached data if that request fails
- **`.returnCacheAndRevalidate(maxAge:)`**: Return cached data immediately and refresh stale data in the background

## Error Handling

Every failure is a `NetworkError`, and each HTTP case carries the rejected `HTTPResponse` (status, headers, body).
Cancelling the calling task always surfaces as `CancellationError`.

```swift
do {
    let user = try await client.request(endpoint, responseType: User.self)
} catch NetworkError.unauthorized {
    // Authentication failed and could not be refreshed
} catch NetworkError.clientError(let response) {
    // The server rejected the request; read response.statusCode or decode response.body
} catch let error as NetworkError where error.isTransient {
    // Timeout, lost connectivity, unreachable host, 429, or 5xx
}
```

`error.category` groups the cases into what a UI treats differently (`.offline`, `.unauthorized`, `.rateLimited`,
...), and `error.retryAfter` carries a parsed `Retry-After`.

`NetworkClient` never retries transient failures unless you opt in with a `NetworkRetryPolicy`, which retries
idempotent requests on `429`, 5xx, timeouts, lost connectivity, and unreachable hosts with capped, jittered backoff:

```swift
let configuration = NetworkClientConfiguration(retryPolicy: NetworkRetryPolicy(maxRetries: 2))
```

See [Handling errors and retries](https://maniramezan.github.io/SwiftyNetwork/documentation/swiftynetwork/handlingerrorsandretries) for the full case table, rate limiting, and retry rules.

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

After a successful authorization refresh the request is replayed at once. Set `authRefreshDelay` only if your API
needs a moment before it accepts a newly issued credential.

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

## Versioning

SwiftyNetwork follows [Semantic Versioning](https://semver.org). The public enums (`NetworkError`,
`NetworkErrorClassification`, `AuthorizationType`, `CachePolicy`, `MutationStatus`,
`MutationFailureReason.Category`, `NetworkReachability`, and `LogLevel`) gain new cases only in a major
release, so an exhaustive `switch` over them keeps compiling across minor and patch releases. Types meant to
grow, such as `HTTPMethod` and `RedirectPolicy`, are structs, so their new values can arrive in any release.

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

SwiftyNetwork's test doubles live in the `SwiftyNetwork` module behind the `Testing` SPI, so a test
target needs only the `SwiftyNetwork` product your app already links. Import the SPI in tests and
previews, never in production code:

```swift
.testTarget(
    name: "MyAppTests",
    dependencies: [
        "MyApp",
        .product(name: "SwiftyNetwork", package: "SwiftyNetwork"),
    ]
)
```

`@testable import` alone doesn't expose SPI; write `@testable @_spi(Testing) import SwiftyNetwork`
when you need both. Keeping the doubles in the core module means a test target always uses the same
copy of SwiftyNetwork as the app, including Xcode apps that load it through dynamic frameworks, so
`NetworkError` casts and retroactive conformances work in tests.

```swift
@_spi(Testing) import SwiftyNetwork
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
`refreshCallCount`, the `rejectedAuthorizations`, and `setRefreshResult(_:)`,
`setRefreshedAuthorization(_:)`, and `setCurrentAuthorization(_:)` to change the script mid-test.
Like the other `Testing` SPI doubles, it is for test targets and previews only.

Stub `.http(HTTPResponse(statusCode: 200, headers: ["ETag": "v2"], body: data))` to script response headers
for code that reads `response(for:responseType:)`. Responses for a route are consumed in order and the last one repeats. Unstubbed routes throw
`MockAPIClient.UnstubbedRequestError` unless you set a fallback with `setFallback(_:)`.

## GraphQL

See [the GraphQL guide](GRAPHQL.md) for typed variables, response envelopes,
partial results, and transport limitations. GraphQL uses the existing HTTP
pipeline; no schema compiler or additional dependency is required.

## Architecture and review

[ARCHITECTURE.md](ARCHITECTURE.md) describes the current implementation and
[REVIEW.md](REVIEW.md) records remaining correctness and performance work.

## Contributing

We welcome contributions! Please read our [CONTRIBUTING.md](CONTRIBUTING.md) guidelines and submit pull requests to our GitHub repository.

### Code Quality

This project uses [swift-format](https://github.com/swiftlang/swift-format) (Apple's official Swift formatter) for code formatting and linting.

#### Local Development

Format code manually:

```bash
swift format format --in-place --recursive --parallel Sources Tests  # Format in-place
swift format lint --recursive --parallel Sources Tests                # Check for violations
```

#### CI

swift-format runs in strict mode on all PRs (warnings treated as errors).
Configuration: `.swift-format`

CI also builds and tests with the minimum (6.2) and latest Swift toolchains, runs the suite on iOS
simulators, and checks pull requests for API breaking changes against the latest release.

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
