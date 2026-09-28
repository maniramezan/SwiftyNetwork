# SwiftyNetwork - Agent Guidelines

> Quick reference for AI coding agents working on this codebase.
> For deeper technical context, see [ARCHITECTURE.md](ARCHITECTURE.md).
> For Claude-specific guidance, see [CLAUDE.md](CLAUDE.md).

## Overview

SwiftyNetwork is a zero-dependency Swift networking library built for Swift 6 strict concurrency. It provides type-safe endpoint definitions, an actor-based HTTP client with retry and auth refresh, a flexible caching system, and a repository pattern for coordinating network and local data.

**Key types to know:**
- `NetworkEndpoint` -- protocol defining API requests (the primary endpoint protocol)
- `NetworkClient` -- actor that executes requests with retry/auth refresh
- `InMemoryCache<T>` / `LayeredCache<T>` -- caching implementations
- `GenericRepository<T>` -- coordinates network + cache with `CachePolicy`
- `AuthorizationProvider` -- protocol for injectable auth (see `OAuthAuthorizationProvider`)
- `MutationQueue` -- actor for fire-and-forget mutations with background retry, coalescing by `MutationKey`, and pluggable persistence via `MutationStore`

## Project Structure

```
Sources/SwiftyNetwork/
├── Logger.swift                     # Internal logging (os.Logger, privacy-aware, lazy messages)
├── Network/
│   ├── NetworkEndpoint.swift        # Endpoint protocol, makeURLRequest(), EndpointURLBuilder
│   ├── APIClient.swift              # APIClient / NetworkDataSource protocols + no-body convenience
│   ├── NetworkClient.swift          # Actor: request pipeline, 401 refresh + replay
│   ├── NetworkClientConfiguration.swift  # Session, coders, auth, timeouts, instrumentation
│   ├── HTTPStatusValidator.swift    # Internal: status code -> NetworkError mapping
│   ├── RequestTrace.swift           # Internal: per-attempt instrumentation reporting
│   ├── EncodedBodyEndpoint.swift    # Internal: body-override wrapper + HTTPHeaders helpers
│   ├── AnySendableError.swift       # Internal: Sendable wrapper for foreign errors
│   ├── HTTPMethod.swift             # HTTP verb enum
│   ├── EmptyResponse.swift          # Decodable for bodiless responses
│   ├── AuthorizationType.swift      # Auth header strategies (Codable)
│   ├── AuthProvider.swift           # AuthorizationProvider protocol + OAuth actor
│   ├── NetworkError.swift           # Error enum, classification, isTransient, URLError mapping
│   ├── NetworkInstrumentation.swift # Observability hook + event types
│   ├── NetworkMonitor.swift         # NWPathMonitor reachability actor
│   └── SSLPinningConfiguration.swift  # Pins, host policies, trust evaluation
├── Cache/
│   ├── Cache.swift                  # Cache, TimestampedCache, PersistentCache protocols
│   ├── CacheKey.swift               # Hashable, string-literal key with factories
│   ├── CachePolicy.swift            # Strategy enum (cacheFirst, reload, expiration)
│   ├── LRUStorage.swift             # Internal: O(1) LRU dictionary (value type)
│   ├── InMemoryCache.swift          # Actor over LRUStorage with timestamps
│   ├── AnyCache.swift               # Type-erased Sendable struct (conforms to Cache)
│   ├── LayeredCache.swift           # Memory + persistent with promotion
│   ├── CacheOperationGate.swift     # Internal: FIFO gate serializing compound cache ops
│   ├── SingleFlightCache.swift      # Coalesces concurrent same-key fetches
│   └── RemoteDataCache.swift        # URL-keyed byte cache on top of SingleFlightCache
├── Repository/
│   └── Repository.swift             # LocalDataSource, CacheBasedLocalDataSource, GenericRepository
└── Mutation/
    ├── MutationQueue.swift          # Actor: enqueue, background retry, coalescing, status via AsyncStream
    ├── MutationRequest.swift        # Codable NetworkEndpoint value type (endpoint + body), replayable
    ├── MutationKey.swift            # Coalescing key
    ├── MutationStatus.swift         # pending/retrying/succeeded/failed + MutationFailureReason
    ├── MutationRetryPolicy.swift    # Exponential backoff + jitter (capped), transient classification
    ├── MutationStore.swift          # Pluggable persistence protocol
    └── InMemoryMutationStore.swift  # Default in-memory MutationStore

Sources/SwiftyNetworkTesting/        # Public test doubles for consumers (separate library product)
├── MockAPIClient.swift              # Scriptable APIClient/NetworkDataSource that records requests
├── RecordedRequest.swift            # Snapshot of a received endpoint
└── MutationRetryPolicy+Testing.swift  # .immediate() zero-backoff policy

Tests/SwiftyNetworkTests/
├── Helpers/TestHelpers.swift        # TestURLProtocol, Gate, FakeAPIClient, TestAuthorizationProvider, ...
├── Network/                         # Client, auth, pinning, instrumentation, errors, endpoint tests
├── Cache/                           # Cache types, LRUStorage, ordering/single-flight, RemoteDataCache
├── Repository/RepositoryTests.swift # All cache policies against a real NetworkClient
├── Mutation/                        # Queue retry/coalescing/status, request/store/policy unit tests
└── Testing/                         # MockAPIClient tests (the public SwiftyNetworkTesting module)
```

## Quick Commands

```bash
# Build
swift build                     # Debug build
swift build -c release          # Release build

# Test
swift test                      # All tests
swift test --filter CacheTests  # Specific suite
swift test --enable-code-coverage  # With coverage

# Format (swift-format, configured via .swift-format)
swift format format -i -r -p Sources Tests   # Format in-place
swift format lint -r -p Sources Tests        # Check violations
swift format lint --strict -r -p Sources Tests  # CI mode (warnings = errors)

# Documentation (DocC)
swift package generate-documentation \
  --target SwiftyNetwork \
  --transform-for-static-hosting \
  --output-path docs
```

## Code Conventions

### Concurrency (Swift 6 strict mode)

- Use `async/await` for all asynchronous operations
- Use `actor` for any shared mutable state
- All public types and protocols must be `Sendable`
- Prefer structured concurrency (`async let`, `TaskGroup`) over unstructured `Task {}`
- Never use GCD, `NSLock`, or completion handlers in new code
- `@unchecked Sendable` requires a documented safety invariant

### Naming

- Types/Protocols/Actors: `PascalCase` (`NetworkClient`, `CachePolicy`)
- Functions/Properties: `lowerCamelCase` (`fetchUser`, `maxAuthRefreshAttempts`)
- Test files: match type name + `Tests` (`NetworkClientTests.swift`)
- Test functions: descriptive using `@Test("description")` attribute

### File Organization

- One primary type per file
- Use `// MARK: -` for logical sections
- Group extensions by responsibility
- DocC comments (`///`) on all public APIs with parameter/return/throws documentation
- 4-space indentation (enforced by swift-format)
- 120-character line length limit

## Testing

**Framework:** Swift Testing (`@Test`, `#expect`, `#require`)

### Rules

- Test both success and failure paths
- Use `#expect(throws:)` for expected errors, not `do/catch` with `Issue.record()`
- Use `#require` when a value is a prerequisite for subsequent assertions
- Use `Issue.record()` only for unreachable-code assertions (not as error matching)
- Use `.serialized` trait only when tests share state that cannot be isolated
- Prefer test isolation over serialization -- each test should create its own instances
- Cover cache expiration, auth refresh, retry, and error mapping paths

### Test Utilities (from `Tests/Helpers/TestHelpers.swift`)

```swift
// Mock responses
TestURLProtocol.Response.success(data)     // 200 with data
TestURLProtocol.Response.status(code)      // Specific HTTP status
TestURLProtocol.Response.failure(error)    // URLError

// Test isolation
makeEndpointWithTestId("unique-id")        // Endpoint with test-id query param
makeTestSession()                          // Ephemeral URLSession with TestURLProtocol

// Auth testing
TestAuthorizationProvider(current:refreshResult:refreshedAuthorization:)

// Scripted APIClient (no URLSession) -- prefer for MutationQueue / repository / service tests
let client = MockAPIClient()                              // from SwiftyNetworkTesting
await client.stub(.post, "/likes", with: .failure(NetworkError.timeout), .empty)
let queue = MutationQueue(client: client, retryPolicy: .immediate())

// Deterministic interleavings -- never rely on sleeps
let gate = Gate(); await gate.wait(); await gate.open()
FakeAPIClient(outcomes:gatesByCallIndex:)                 // per-call gating for MutationQueue races

// Pattern for isolated NetworkClient tests:
let session = makeTestSession()
let config = NetworkClientConfiguration(session: session, retryDelay: 0)
let client = NetworkClient(configuration: config)
TestURLProtocol.setResponses([.success(data)], for: "test-id")
let endpoint = makeEndpointWithTestId("test-id")
```

### Toolchain availability

Some cloud agent sandboxes cannot download a Swift toolchain. If `swift` is missing, say so, keep
changes conservative (no API you can't verify from existing code), and rely on the PR's GitHub
Actions run (`format` → `build` → `test`, plus `Docs`) as the compiler. Never claim tests passed
when they were not run.

## Git Workflow

### Commits

- Imperative mood: `"Add cache size limits"` not `"Added..."`
- Optional scope prefix: `cache:`, `network:`, `docs:`, `tests:`, `repo:`
- Reference issues: `Fixes #123`
- Do not add `Co-Authored-By: Codex` or other Codex attribution trailers to commits.

### Pull Requests

- Summary of changes and architectural impact
- Testing evidence (test output, coverage)
- Migration notes if breaking changes
- Do not create or maintain changelog files. Describe user-facing changes and migration notes in PR descriptions.

## Architecture Quick Reference

### Request Flow

```
NetworkClient.request(endpoint) →
  buildURL → buildURLRequest → applyAuthorization →
  URLSession.data(for:) → validateResponse →
  [401? → refreshAuth → retry] → validateStatusCode → decode
```

### Repository Flow

```
GenericRepository.fetch(endpoint, cacheKey, policy) →
  [.returnCacheElseLoad]        → cache hit? return : fetch + cache
  [.reloadIgnoringCache]        → always fetch + cache
  [.returnCacheIfNotExpired]    → cache fresh? return : fetch + cache
```

### Mutation Flow

```
MutationQueue.enqueue(request, key) → store.save (coalescing point) → returns immediately
  background Task per key:
    load → APIClient.request → success? → removeIfCurrent(request) → .succeeded
                                        ↳ store changed (coalesced replacement)? → process it next
                              → failure? → retryable && attempts left? → .retrying → backoff → retry
                                        ↳ else → removeIfCurrent(request) → .failed
                                              ↳ store changed? → process replacement next instead
```

### Cache Hierarchy

```
Cache (protocol) → TimestampedCache → InMemoryCache<T> (actor, O(1) LRU via LRUStorage)
                 → PersistentCache (marker, you implement)
                 → LayeredCache<T> (actor, memory + persistent, ops serialized by CacheOperationGate)
                 → SingleFlightCache<Wrapped> (actor, dedupes concurrent misses per key)
AnyCache<T> (type-erased Sendable struct)
RemoteDataCache<Wrapped> (actor, URL → Data, wraps SingleFlightCache)
```

### Key Design Points

- `NetworkEndpoint` is the only endpoint protocol (has defaults, used by NetworkClient)
- `makeURLRequest()` is an extension on `NetworkEndpoint` in `NetworkEndpoint.swift` (standalone URL building)
- `AnyCache` conforms to `Cache` protocol -- struct with immutable `@Sendable` closures
- `retryDelay` applies `Task.sleep(for:)` before auth retry; use `retryDelay: 0` in tests
- On 401 the client calls `AuthorizationProvider.refreshAuthorization(rejecting:)` with the exact
  provider authorization it sent, so providers can skip refreshing a token that was already replaced
- Every exit from the request pipeline reports through `RequestTrace` (started/completed/failed/retried);
  add new exit paths through it rather than calling `NetworkInstrumentation` directly
- `NetworkError.mapURLError` is the single transport-error mapping; connectivity-loss codes map to
  `.noInternetConnection` (transient), other `URLError`s are kept intact in `.underlying`
- `Logger` messages are `@autoclosure`; don't pre-build strings or guard on `Logger.level` at call sites
- `request(_:body:responseType:)` encodes `Encodable` bodies with config's encoder
- All actors use instance isolation -- no locks or GCD in production code
- `TestURLProtocolState` uses `NSLock` because `URLProtocol.startLoading()` is synchronous
- `MutationRequest` is `Codable` (not a closure) so a durable `MutationStore` can serialize
  "which endpoint plus what body" and replay it after relaunch
- Coalescing correctness relies on `MutationStore.removeIfCurrent(_:for:)` being a single,
  non-suspending check-and-remove -- composing `load` then `remove` from outside reintroduces
  the race it exists to close

## Security

- Never commit API keys, tokens, credentials, or production URLs
- Inject auth via `AuthorizationProvider` -- never hardcode tokens
- Scrub sensitive headers before logging
- `Logger` marks URLs and underlying errors private; redact sensitive values before exporting diagnostics
- Validate URLs (scheme + host) in endpoints
- `MutationRequest` can carry secrets via its captured `AuthorizationType` (bearer tokens, API
  keys); a durable `MutationStore` implementation is responsible for encrypting persisted
  mutations (e.g. Keychain-backed) -- SwiftyNetwork does not encrypt them itself

## Documentation Files

| File | Purpose |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | Deep technical guide: type hierarchy, data flow, concurrency model |
| [AGENTS.md](AGENTS.md) | This file -- AI agent quick reference |
| [CLAUDE.md](CLAUDE.md) | Claude-specific guidance, skills, and workflow |
| [README.md](README.md) | User-facing documentation with installation and examples |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Human contributor guide: setup, style, PR process |
| [PLAN.md](PLAN.md) | Feature planning checklist and decision framework |
| [REVIEW.md](REVIEW.md) | Open review findings, evolution constraints, and validation history |
| [GRAPHQL.md](GRAPHQL.md) | GraphQL-over-HTTP recipe and limitations |
| [SECURITY.md](SECURITY.md) | Vulnerability reporting and integration security boundaries |
| [.claude/skills/](.claude/skills) | Repo-specific agent workflows: adding components, tests, concurrency review, pre-push checks |
