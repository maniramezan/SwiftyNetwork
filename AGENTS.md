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
├── Logger.swift              # Internal logging (NSLog, DEBUG-gated)
├── Network/
│   ├── HTTPMethod.swift      # HTTP verb enum
│   ├── AuthorizationType.swift  # Auth header strategies
│   ├── AuthProvider.swift    # AuthorizationProvider protocol + OAuth actor
│   ├── Endpoint.swift        # NetworkEndpoint.makeURLRequest() extension
│   ├── ClientAPI.swift       # NetworkEndpoint, APIClient, NetworkDataSource, NetworkClient
│   ├── NetworkError.swift    # Error enum with LocalizedError
│   └── NetworkMonitor.swift  # NWPathMonitor reachability actor
├── Cache/
│   ├── Cache.swift           # Cache, TimestampedCache, PersistentCache protocols
│   ├── CacheKey.swift        # Hashable key with convenience factories
│   ├── CachePolicy.swift     # Strategy enum (cacheFirst, reload, expiration)
│   ├── InMemoryCache.swift   # Actor with LRU eviction
│   ├── AnyCache.swift        # Type-erased wrapper (conforms to Cache, @unchecked Sendable)
│   └── LayeredCache.swift    # Memory + persistent with promotion
├── Repository/
│   └── Repository.swift      # LocalDataSource, CacheBasedLocalDataSource, GenericRepository
└── Mutation/
    ├── MutationQueue.swift        # Actor: enqueue, background retry, coalescing, status via AsyncStream
    ├── MutationRequest.swift      # Codable NetworkEndpoint value type (endpoint + body), replayable
    ├── MutationKey.swift          # Coalescing key
    ├── MutationStatus.swift       # pending/retrying/succeeded/failed + MutationFailureReason
    ├── MutationRetryPolicy.swift  # Exponential backoff + jitter, transient-error classification
    ├── MutationStore.swift        # Pluggable persistence protocol
    └── InMemoryMutationStore.swift  # Default in-memory MutationStore

Tests/SwiftyNetworkTests/
├── Helpers/TestHelpers.swift # TestURLProtocol, TestAuthorizationProvider, factories
├── Network/                  # 20 tests across 7 files
├── Cache/CacheTests.swift    # 22 tests covering all cache types
├── Repository/RepositoryTests.swift  # 7 tests covering all policies
└── Mutation/                 # Queue retry/coalescing/status, request/store/policy unit tests
```

## Quick Commands

```bash
# Build
swift build                     # Debug build
swift build -c release          # Release build

# Test
swift test                      # All tests (~60 tests)
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
- Functions/Properties: `lowerCamelCase` (`fetchUser`, `maxRetryAttempts`)
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

// Pattern for isolated NetworkClient tests:
let session = makeTestSession()
let config = NetworkClientConfiguration(session: session, retryDelay: 0)
let client = NetworkClient(configuration: config)
TestURLProtocol.setResponses([.success(data)], for: "test-id")
let endpoint = makeEndpointWithTestId("test-id")
```

## Git Workflow

### Commits

- Imperative mood: `"Add cache size limits"` not `"Added..."`
- Optional scope prefix: `cache:`, `network:`, `docs:`, `tests:`, `repo:`
- Reference issues: `Fixes #123`
- Co-author tag for AI contributions (see CLAUDE.md for Claude-specific tag)

### Pull Requests

- Summary of changes and architectural impact
- Testing evidence (test output, coverage)
- Migration notes if breaking changes
- Update CHANGELOG.md for user-facing changes

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
Cache (protocol) → TimestampedCache → InMemoryCache<T> (actor, LRU)
                 → PersistentCache (marker, you implement)
                 → LayeredCache<T> (actor, memory + persistent)
AnyCache<T> (type-erased wrapper, @unchecked Sendable)
```

### Key Design Points

- `NetworkEndpoint` is the only endpoint protocol (has defaults, used by NetworkClient)
- `makeURLRequest()` is an extension on `NetworkEndpoint` in `Endpoint.swift` (standalone URL building)
- `AnyCache` conforms to `Cache` protocol -- type-erased wrapper with `@unchecked Sendable`
- `retryDelay` applies `Task.sleep(for:)` before auth retry; use `retryDelay: 0` in tests
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
- `Logger` never logs tokens, credentials, or PII
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
| [CHANGELOG.md](CHANGELOG.md) | Version history and breaking changes |
