# SwiftyNetwork Architecture

> Comprehensive technical guide for understanding, contributing to, and integrating SwiftyNetwork.

## Table of Contents

- [System Overview](#system-overview)
- [Module Structure](#module-structure)
- [Type Hierarchy and Relationships](#type-hierarchy-and-relationships)
- [Data Flow](#data-flow)
- [Concurrency Model](#concurrency-model)
- [Extension Points](#extension-points)
- [Documentation Map](#documentation-map)
- [Integration Guide](#integration-guide)
- [Known Design Decisions and Trade-offs](#known-design-decisions-and-trade-offs)

---

## System Overview

SwiftyNetwork is a zero-dependency Swift networking library built for Swift 6+ strict concurrency. It provides three coordinated subsystems:

1. **Network** -- HTTP client with endpoint abstraction, authorization, and retry logic
2. **Cache** -- Protocol-based caching with in-memory, layered, and custom persistent implementations
3. **Repository** -- Data coordination layer that combines network and cache with configurable policies

```
┌─────────────────────────────────────────────────────┐
│                   Consumer Code                      │
│         (your app / another Swift package)            │
└────────────────────────┬────────────────────────────┘
                         │
          ┌──────────────┼──────────────┐
          │              │              │
          ▼              ▼              ▼
   ┌────────────┐ ┌────────────┐ ┌────────────┐
   │  Network   │ │   Cache    │ │ Repository │
   │  Subsystem │ │  Subsystem │ │  Subsystem │
   └────────────┘ └────────────┘ └────────────┘
```

### Package Configuration

| Property | Value |
|---|---|
| Swift Tools Version | 6.0 |
| Swift Language Mode | v6 (strict concurrency) |
| Platforms | macOS 15+, iOS 15+ |
| Runtime Dependencies | None |
| Dev Dependencies | swift-format (602.0.0+) |

---

## Module Structure

```
Sources/SwiftyNetwork/
├── Logger.swift                    # Internal logging (NSLog-based, DEBUG-gated)
├── Network/
│   ├── HTTPMethod.swift            # HTTP verb enum (GET, POST, PUT, DELETE, PATCH)
│   ├── AuthorizationType.swift     # Auth header strategies (bearer, basic, apiKey, custom)
│   ├── AuthProvider.swift          # AuthorizationProvider protocol + OAuthAuthorizationProvider actor
│   ├── Endpoint.swift              # NetworkEndpoint.makeURLRequest() extension (URL builder)
│   ├── ClientAPI.swift             # NetworkEndpoint, APIClient, NetworkDataSource, NetworkClient
│   ├── NetworkError.swift          # Comprehensive error enum with LocalizedError
│   └── NetworkMonitor.swift        # NWPathMonitor-based reachability actor
├── Cache/
│   ├── Cache.swift                 # Cache, TimestampedCache, PersistentCache protocols
│   ├── CacheKey.swift              # Hashable cache key with convenience factories
│   ├── CachePolicy.swift           # Cache strategy enum (cacheFirst, reload, expiration)
│   ├── InMemoryCache.swift         # Actor-based in-memory cache with LRU eviction
│   ├── AnyCache.swift              # Type-erased cache wrapper (closure-based, conforms to Cache)
│   └── LayeredCache.swift          # Two-tier cache (memory + persistent) with promotion
└── Repository/
    └── Repository.swift            # LocalDataSource, CacheBasedLocalDataSource, GenericRepository

Tests/SwiftyNetworkTests/
├── Helpers/
│   └── TestHelpers.swift           # TestURLProtocol, TestAuthorizationProvider, factory helpers
├── Network/
│   ├── NetworkClientTests.swift    # Integration tests for NetworkClient (parallel, test-id isolated)
│   ├── EndpointTests.swift         # NetworkEndpoint URL building tests
│   ├── AuthProviderTests.swift     # OAuthAuthorizationProvider tests
│   ├── AuthorizationTypeTests.swift# Auth header application tests
│   ├── HTTPMethodTests.swift       # Enum raw value tests
│   ├── NetworkErrorTests.swift     # Error descriptions and data extraction
│   └── NetworkMonitorTests.swift   # Initial reachability state test
├── Cache/
│   └── CacheTests.swift            # All cache types + policies + LRU eviction
└── Repository/
    └── RepositoryTests.swift       # Repository pattern with all 3 cache policies
```

---

## Type Hierarchy and Relationships

### Network Layer

```
NetworkEndpoint (protocol, Sendable)
    │  - baseURL, path, method
    │  - queryItems, headers, body
    │  - authorization
    │  (has default implementations)
    │  + makeURLRequest() (extension in Endpoint.swift)
    │
    ▼
APIClient (protocol, Sendable)
    │  - request(_:responseType:)
    │
    ▼
NetworkDataSource (protocol)
    │  (marker protocol, extends APIClient)
    │
    ▼
NetworkClient (actor)
    ├─ configuration: NetworkClientConfiguration
    ├─ requestCount: Int
    ├─ static shared: NetworkClient
    ├─ request(_:responseType:) → standard request
    ├─ request(_:body:responseType:) → encodes body with config's encoder
    └─ performRequest() → buildURL() → applyAuthorization()
                          → execute → validate → decode
                          → handle 401 → refresh → retryDelay → retry
```

**Single Endpoint Protocol**: `NetworkEndpoint` is the only endpoint protocol. It defines the request shape with sensible defaults. An extension in `Endpoint.swift` adds `makeURLRequest()` for standalone URL building (e.g., outside of `NetworkClient`). `NetworkClient` uses `NetworkEndpoint` exclusively and builds URLs internally.

### Cache Layer

```
Cache (protocol, AnyObject, Sendable)
    │  Associated type: Value: Sendable
    │  - value(forKey:), setValue(_:forKey:)
    │  - removeValue(forKey:), removeAll()
    │  - timestamp(forKey:)
    │
    ├── TimestampedCache (protocol, extends Cache)
    │       │  - setValue(_:forKey:timestamp:)
    │       │
    │       └── InMemoryCache<T> (actor)
    │               - LRU eviction via maxSize
    │               - removeExpiredEntries(maxAge:)
    │               - removeEntries(olderThan:)
    │
    ├── PersistentCache (protocol, marker, extends Cache)
    │       (consumers implement this for disk/database backing)
    │
    └── LayeredCache<T> (actor, conforms to Cache)
            - memory tier (any TimestampedCache or Cache)
            - optional persistent tier (any Cache)
            - promotes values from persistent → memory on read
            - preserves timestamps during promotion

AnyCache<T> (final class, @unchecked Sendable, conforms to Cache)
    - Type-erased wrapper over any Cache
    - Closure-based forwarding
    - Conforms to Cache protocol
    - Used by CacheBasedLocalDataSource and LayeredCache internals
    - Safety invariant: closures capture actor-isolated methods,
      so concurrent calls are serialized by the underlying actor
```

### Repository Layer

```
LocalDataSource (protocol)
    │  Associated type: Entity: Sendable
    │  - read(for:), write(_:for:), remove(for:), removeAll()
    │  - timestamp(for:)
    │
    └── CacheBasedLocalDataSource<E> (struct)
            - Wraps AnyCache<E>
            - Bridges cache operations to LocalDataSource interface

Repository (protocol)
    │  Associated type: Entity: Sendable
    │  - fetch(using:cacheKey:policy:)
    │
    └── GenericRepository<Entity: Decodable & Sendable> (struct)
            - networkDataSource: any NetworkDataSource
            - localRead/localWrite/localTimestamp (type-erased closures)
            - Implements all 3 CachePolicy strategies
```

### Authorization

```
AuthorizationProvider (protocol, Sendable)
    │  - currentAuthorization() async → AuthorizationType
    │  - refreshAuthorizationIfNeeded() async → Bool
    │
    └── OAuthAuthorizationProvider (actor)
            - Stores access token
            - Calls injected refresh handler
            - Returns .bearer(token:) authorization

AuthorizationType (enum, Sendable)
    - .none
    - .basic(token:)
    - .bearer(token:)
    - .apiKey(key:, header:)
    - .custom(header:, value:)
    + apply(to: inout URLRequest)
```

---

## Data Flow

### Simple Network Request

```
Consumer
    │
    ▼
NetworkClient.request(endpoint, responseType:)
    │
    ├── buildURL(from: endpoint)              → URL
    ├── buildURLRequest(from: endpoint, url:) → URLRequest
    ├── applyAuthorization(to: &request)      → applies endpoint or provider auth
    ├── URLSession.data(for: request)         → (Data, URLResponse)
    ├── validateResponse()                    → HTTPURLResponse
    ├── [if 401] handleUnauthorizedResponse() → refresh + retryDelay + retry (up to maxRetryAttempts)
    ├── validateStatusCode()                  → maps to NetworkError
    └── decodeResponse()                      → T
```

### Repository Fetch (with caching)

```
Consumer
    │
    ▼
GenericRepository.fetch(using: endpoint, cacheKey:, policy:)
    │
    ├── [.returnCacheElseLoad]
    │       ├── localRead(cacheKey) → hit? return cached
    │       └── miss → fetchFromNetworkAndCache()
    │
    ├── [.reloadIgnoringCache]
    │       └── fetchFromNetworkAndCache() always
    │
    └── [.returnCacheIfNotExpired(maxAge:)]
            ├── localRead(cacheKey) + localTimestamp(cacheKey)
            │       → fresh? return cached
            └── stale/miss → fetchFromNetworkAndCache()

fetchFromNetworkAndCache():
    ├── networkDataSource.request(endpoint, responseType:) → T
    └── localWrite(entity, cacheKey) → cache for next time
```

### Layered Cache Read

```
LayeredCache.value(forKey: key)
    │
    ├── memoryCache.value(forKey: key)
    │       → hit? return value
    │
    └── persistentCache.value(forKey: key)
            → hit? promote to memory (with timestamp) → return value
            → miss? return nil
```

---

## Concurrency Model

SwiftyNetwork uses Swift 6 strict concurrency throughout. The key safety mechanisms are:

### Actor Isolation

All mutable state is protected by actor isolation:

| Type | Isolation | Mutable State |
|---|---|---|
| `NetworkClient` | actor | `configuration`, `requestCount` |
| `InMemoryCache<T>` | actor | `storage`, `accessOrder` |
| `LayeredCache<T>` | actor | `memoryCache`, `persistentCache` references |
| `OAuthAuthorizationProvider` | actor | `accessToken` |
| `NetworkMonitor` | actor | `status`, `isMonitoring` |

### Sendable Conformance

- All protocols require `Sendable` (either directly or via `associatedtype: Sendable`)
- `AnyCache` is `@unchecked Sendable` -- safe because its closures capture actor-isolated methods
- `GenericRepository` is a struct with no mutable state -- its closures capture actor-isolated data sources
- `CacheBasedLocalDataSource` is a struct delegating to `AnyCache`

### Thread Safety Rules for Contributors

1. New mutable shared state must be in an `actor`
2. New public types must conform to `Sendable`
3. Do not use `@unchecked Sendable` without documenting the safety invariant
4. Prefer structured concurrency (`async let`, `TaskGroup`) over unstructured `Task {}`
5. Do not use GCD, locks, or completion handlers

---

## Extension Points

### Adding a Custom Persistent Cache

Implement the `PersistentCache` protocol (which extends `Cache`), then use it with `LayeredCache`:

```swift
public actor DiskCache<T: Codable & Sendable>: PersistentCache {
    public typealias Value = T
    // Implement: value(forKey:), setValue(_:forKey:), removeValue(forKey:),
    //           removeAll(), timestamp(forKey:)
}

// Compose with LayeredCache:
let layered = LayeredCache(
    memoryCache: InMemoryCache<MyModel>(),
    persistentCache: DiskCache<MyModel>()
)
```

### Adding a Custom Authorization Provider

Implement `AuthorizationProvider`:

```swift
public actor JWTAuthorizationProvider: AuthorizationProvider {
    public func currentAuthorization() async -> AuthorizationType {
        .bearer(token: currentJWT)
    }
    public func refreshAuthorizationIfNeeded() async -> Bool {
        // Refresh JWT logic
    }
}
```

### Adding New Endpoint Patterns

Conform to `NetworkEndpoint` for any new API shape:

```swift
struct GraphQLEndpoint: NetworkEndpoint {
    let baseURL: String
    var path: String { "/graphql" }
    var method: HTTPMethod { .post }
    var body: Data? { try? JSONEncoder().encode(query) }
    var headers: [String: String]? { ["Content-Type": "application/json"] }
}
```

### Adding New Error Cases

Extend `NetworkError` with new cases, then handle them in `NetworkClient.validateStatusCode(_:data:)` and add `errorDescription` entries.

---

## Documentation Map

This section explains how all documentation files relate to each other and when to use each one.

```
ARCHITECTURE.md  ← You are here (technical deep-dive, type relationships, data flow)
    │
    ├── AGENTS.md        ← AI agent quick-reference (conventions, commands, patterns)
    │   └── CLAUDE.md    ← Claude-specific extensions (skills, co-author tag, workflow)
    │
    ├── README.md        ← User-facing docs (installation, quick start, examples)
    ├── CONTRIBUTING.md  ← Human contributor guide (setup, style, PR process)
    ├── PLAN.md          ← Feature planning checklist and decision framework
    └── CHANGELOG.md     ← Version history and breaking changes
```

| Document | Audience | Purpose | When to Read |
|---|---|---|---|
| **ARCHITECTURE.md** | AI agents, new contributors | Deep technical understanding | First time working on the codebase |
| **AGENTS.md** | All AI coding agents | Quick-reference conventions and commands | Every session (loaded automatically) |
| **CLAUDE.md** | Claude specifically | Claude-specific skills, tools, workflow | Loaded by Claude alongside AGENTS.md |
| **README.md** | Library consumers | Installation and usage examples | Integrating SwiftyNetwork |
| **CONTRIBUTING.md** | Human contributors | Development setup and PR process | Before first contribution |
| **PLAN.md** | Feature developers | Planning checklist and decision framework | Before starting a new feature |
| **CHANGELOG.md** | All | Breaking changes and migration paths | After upgrading versions |

### For AI Agents

When an AI agent starts a session on this codebase:

1. **AGENTS.md** is the primary entry point -- it contains all conventions, commands, and patterns
2. **CLAUDE.md** (if using Claude) adds Claude-specific guidance and references AGENTS.md
3. **ARCHITECTURE.md** provides deeper context when the task requires understanding type relationships or data flow
4. **PLAN.md** guides feature planning with checklists

---

## Integration Guide

### Adding SwiftyNetwork to Your Project

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/maniramezan/SwiftyNetwork.git", from: "1.0.0")
]
```

### Minimal Setup

```swift
import SwiftyNetwork

// 1. Define an endpoint
struct UsersEndpoint: NetworkEndpoint {
    let baseURL = "https://api.example.com"
    var path: String { "/users" }
    var method: HTTPMethod { .get }
}

// 2. Make a request
let user = try await NetworkClient.shared.request(
    UsersEndpoint(),
    responseType: User.self
)
```

### Full Setup with Repository Pattern

```swift
import SwiftyNetwork

// 1. Configure client
let config = NetworkClientConfiguration(
    authorizationProvider: myAuthProvider,
    maxRetryAttempts: 2,
    timeoutInterval: 30
)
let client = NetworkClient(configuration: config)

// 2. Set up caching
let cache = InMemoryCache<User>(maxSize: 100)
let local = CacheBasedLocalDataSource(cache: AnyCache(cache))

// 3. Create repository
let repo = GenericRepository(networkDataSource: client, localDataSource: local)

// 4. Fetch with policy
let user = try await repo.fetch(
    using: UsersEndpoint(),
    cacheKey: .user("123", resource: "profile"),
    policy: .returnCacheIfNotExpired(maxAge: 300)
)
```

---

## Known Design Decisions and Trade-offs

### AnyCache Uses @unchecked Sendable

`AnyCache` conforms to `Cache` and is marked `@unchecked Sendable`. Its safety invariant is that all stored closures capture actor-isolated cache methods, so concurrent calls are serialized by the underlying actor. This is documented in the source.

### retryDelay Is Applied Before Auth Retry

`NetworkClientConfiguration.retryDelay` (default 1.0 second) is applied via `Task.sleep(for:)` before retrying a request after a successful auth refresh on 401. Set `retryDelay: 0` in test configurations to avoid slowing down the test suite.

### encoder Convenience Method

`NetworkClient` provides a `request(_:body:responseType:)` overload that encodes `Encodable` bodies using the configuration's encoder. It wraps the original endpoint in an internal `EncodedBodyEndpoint` that overrides the `body` property. The original `request(_:responseType:)` still works with raw `Data` bodies.

### NetworkMonitor Uses Unstructured Task in Callback

`NetworkMonitor.startMonitoring()` creates an unstructured `Task` in its `pathUpdateHandler` because `NWPathMonitor`'s callback is synchronous and non-async. The handler uses `[weak self]` to avoid retain cycles.

### TestURLProtocolState Uses NSLock (Not Actor)

`TestURLProtocolState` in test helpers uses `NSLock` rather than an actor because `URLProtocol.startLoading()` is called synchronously on URLSession's internal threads. An actor would require `await` which is not available in a synchronous context. `Mutex` (from Synchronization framework) requires iOS 18+, which exceeds the package's iOS 15+ minimum. `NSLock` is the correct choice here.

### Static Singleton Pattern

`NetworkClient.shared` and `NetworkMonitor.shared` use static singletons. For testing, always create fresh instances with custom configurations rather than using the singletons.
