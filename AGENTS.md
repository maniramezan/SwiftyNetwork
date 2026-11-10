# SwiftyNetwork - Agent Guidelines

> Quick reference for AI coding agents working on this codebase.
> For deeper technical context, see [ARCHITECTURE.md](ARCHITECTURE.md).
> For Claude-specific guidance, see [CLAUDE.md](CLAUDE.md).

## Overview

SwiftyNetwork is a Swift networking library, depending only on [SwiftCommons](https://github.com/maniramezan/SwiftCommons) (with `traits: []`), built for Swift 6 strict concurrency. It provides type-safe endpoint definitions, an actor-based HTTP client with retry and auth refresh, a flexible caching system, and a repository pattern for coordinating network and local data.

**Key types to know:**
- `NetworkEndpoint` -- protocol defining API requests (the primary endpoint protocol)
- `NetworkClient` -- actor that executes requests with retry/auth refresh
- `InMemoryCache<T>` / `LayeredCache<T>` -- caching implementations
- `GenericRepository<T>` -- coordinates network + cache with `CachePolicy`
- `AuthorizationProvider` -- protocol for injectable auth (see `OAuthAuthorizationProvider`);
  `currentAuthorization()` throws, surfacing as `NetworkError.authorizationUnavailable` without sending
- `MutationQueue` -- actor for fire-and-forget mutations with background retry, coalescing by `MutationKey`, and pluggable persistence via `MutationStore`

## Project Structure

```
Sources/SwiftyNetwork/
├── Logger.swift              # Internal logging (SwiftCommons LibraryLogger, privacy-aware)
├── Network/
│   ├── Client/
│   │   ├── NetworkClient.swift             # Actor: request pipeline, 401 refresh + replay
│   │   ├── NetworkClient+RawRequests.swift # sendAuthorized: raw URLRequest + caller transport with auth/refresh-once
│   │   ├── NetworkClientConfiguration.swift# Session, coders, auth, retry/redirect policies, timeouts, instrumentation
│   │   ├── RequestTrace.swift              # Internal: per-attempt instrumentation reporting
│   │   ├── NetworkInstrumentation.swift    # Observability hook + event types
│   │   └── NetworkMonitor.swift            # NWPathMonitor reachability actor
│   ├── Endpoint/
│   │   ├── NetworkEndpoint.swift           # Endpoint protocol, makeURLRequest(), EndpointURLBuilder
│   │   ├── TypedEndpoint.swift             # Endpoint with its associated response type
│   │   ├── EncodedBodyEndpoint.swift       # Internal: body-override wrapper + HTTPHeaders helpers
│   │   ├── HTTPMethod.swift                # Extensible HTTP method struct (string literals for custom verbs)
│   │   ├── EmptyResponse.swift             # Decodable for bodiless responses
│   │   ├── APIClient.swift                 # APIClient protocol (response(for:) requirement) + request conveniences
│   │   └── DecodedResponse.swift           # Decoded value + HTTPResponse returned by response(for:responseType:)
│   ├── Authorization/
│   │   ├── AuthorizationType.swift         # Auth header strategies
│   │   ├── AuthProvider.swift              # AuthorizationProvider protocol + OAuth actor
│   │   └── AuthorizationRefreshCoalescer.swift# Shared single-flight refresh for custom providers + ReentrantRefreshError
│   ├── Response/
│   │   ├── NetworkError.swift              # Error enum, classification, category, isTransient, URLError mapping
│   │   ├── HTTPResponse.swift              # Status, headers, body (+ Retry-After) for successes and NetworkError
│   │   └── HTTPStatusValidator.swift       # Internal: status code -> NetworkError mapping
│   ├── Retry/
│   │   ├── BackoffPolicy.swift             # Shared jittered exponential backoff + Retry-After floor
│   │   ├── NetworkRetryPolicy.swift        # Opt-in idempotent-request retry policy (429/5xx/timeout/offline)
│   │   └── RetryAfter.swift                # Internal: Retry-After parsing (delta-seconds + HTTP-date)
│   └── Security/
│       ├── SSLPinningConfiguration.swift   # Pins, host policies, trust evaluation
│       ├── RedirectGuard.swift             # Internal: per-task delegate applying RedirectPolicy, Origin comparison
│       └── RedirectPolicy.swift            # Redirect handling presets (default strips credentials across origins)
├── Cache/
│   ├── Cache.swift                     # Cache<Value> protocol, CacheEntry, value/setValue conveniences
│   ├── CacheKey.swift                  # Hashable, string-literal key with factories
│   ├── CachePolicy.swift               # Cache-first, reload, expiry, fallback, revalidation policies
│   ├── Storage/
│   │   ├── InMemoryCache.swift             # Actor over LRUStorage with timestamps
│   │   ├── LRUStorage.swift                # Internal: O(1) LRU dictionary (value type)
│   │   ├── DiskCache.swift                 # Codable file cache with byte and idle-time limits
│   │   └── LayeredCache.swift              # Memory + persistent with promotion
│   └── Coordination/
│       ├── CacheOperationGate.swift        # Internal: FIFO gate serializing compound cache ops
│       ├── SingleFlightCache.swift         # Coalesces concurrent same-key fetches
│       └── RemoteDataCache.swift           # URL-keyed byte cache on top of SingleFlightCache
├── Repository/
│   ├── Repository.swift             # Repository<Entity> protocol, GenericRepository (client + any Cache)
│   ├── RepositoryResult.swift       # Value + source + fetch timestamp
│   └── FetchCoalescer.swift         # Same-key repository network request coalescing
└── Mutation/
    ├── MutationQueue.swift             # Actor: enqueue, background retry, coalescing, status via AsyncStream
    ├── MutationRequest.swift           # Codable NetworkEndpoint value type (endpoint + body), replayable
    ├── MutationKey.swift               # Coalescing key
    ├── MutationStatus.swift            # pending/retrying/succeeded/failed + MutationFailureReason (category: offline/rejected/...)
    ├── MutationRetryPolicy.swift       # Exponential backoff + jitter (capped), transient classification
    └── Store/
        ├── MutationStore.swift             # Pluggable persistence protocol
        ├── InMemoryMutationStore.swift     # Default in-memory MutationStore
        └── FileMutationStore.swift         # Durable file-backed MutationStore
└── Testing/                            # Public test doubles, all `@_spi(Testing) public`
    ├── MockAPIClient.swift                 # Scriptable APIClient that records requests
    ├── RecordedRequest.swift               # Snapshot of a received endpoint
    ├── TestAuthorizationProvider.swift     # Scriptable AuthorizationProvider spy
    ├── NetworkInstrumentationRecorder.swift # Records NetworkInstrumentation events
    ├── BackoffPolicy+Testing.swift         # BackoffPolicy.immediate (zero wait, ignores Retry-After)
    ├── MutationRetryPolicy+Testing.swift   # .immediate() zero-backoff policy
    └── NetworkRetryPolicy+Testing.swift    # .immediate() zero-backoff request retry policy

Tests/SwiftyNetworkTests/
├── Helpers/                         # TestHTTPStub, RedirectingURLProtocol, FakeAPIClient, TestAuthorizationProvider, ...
├── Network/                         # Client/, Endpoint/, Authorization/, Response/, Retry/, Security/ tests
├── Cache/                           # Storage/ (types, LRUStorage, disk) and Coordination/ (ordering, single-flight, RemoteDataCache)
├── Repository/RepositoryTests.swift # All cache policies against a real NetworkClient
├── Mutation/                        # Queue retry/coalescing/status, request/policy tests; Store/ for stores
└── Testing/                         # Tests for the `Testing` SPI doubles (MockAPIClient, TestAuthorizationProvider)
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

# Test on an iOS simulator. xcodebuild can't spread Swift Testing across simulator clones; the
# suite still runs in parallel inside one test process.
xcodebuild test -scheme SwiftyNetwork \
  -destination 'platform=iOS Simulator,name=<iPhone>' \
  -parallel-testing-enabled NO

# API breaking changes against the latest release (CI job `api-breakage`; see CONTRIBUTING.md)
swift package diagnose-api-breaking-changes <latest-tag> --products SwiftyNetwork

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
- Import SwiftCommons with `internal import SwiftCommons`; never expose its types in public API.
- Public enums gain cases only in a major release (documented in README "Versioning"). For a set of
  values that should grow in a minor release, use a struct with static members, like `HTTPMethod`
  and `RedirectPolicy`.
- Reuse SwiftCommons primitives instead of adding local copies: `AsyncBroadcaster` for multi-consumer
  `AsyncStream`s, `RetryBackoff` for backoff math, `AnySendableError` for boxing errors in
  `NetworkError`, `LibraryLogger` (via the internal `Logger`), `DecodingError.debugSummary`,
  `Duration.timeInterval`, and `trimmingSuffix(while:)`. Use Swift’s built-in prefix trimming.

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
TestHTTPStub.Response.success(data)     // 200 with data
TestHTTPStub.Response.status(code)      // Specific HTTP status
TestHTTPStub.Response.failure(error)    // URLError

// Test isolation
makeEndpointWithTestId("unique-id")        // Endpoint with test-id query param
let stub = try TestHTTPStub()              // Per-test StubbedURLSession owner
defer { stub.invalidate() }
stub.session                              // Inject into the client/cache

// Auth testing
TestAuthorizationProvider(current:refreshResult:refreshedAuthorization:shouldRefresh:)

// Scripted APIClient (no URLSession) -- prefer for MutationQueue / repository / service tests
// MockAPIClient and the other doubles need `@testable @_spi(Testing) import SwiftyNetwork`
let client = MockAPIClient()
await client.stub(.post, "/likes", with: .failure(NetworkError.timeout(nil)), .empty)
let queue = MutationQueue(client: client, retryPolicy: .immediate())

// Deterministic interleavings -- never rely on sleeps
let fake = FakeAPIClient(outcomes: [.success])
let gate = await fake.hold(call: 0) // register before starting the operation
// Start work, observe the in-flight state, then release the call.
gate.open()
// FakeAPIClient uses TestCommons ScriptedResponder for per-call gating.

// Pattern for isolated NetworkClient tests:
let stub = try TestHTTPStub()
defer { stub.invalidate() }
let session = stub.session
let config = NetworkClientConfiguration(session: session, authRefreshDelay: .zero)
let client = NetworkClient(configuration: config)
stub.setResponses([.success(data)], for: "test-id")
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
  [.reloadElseReturnCache]      → fetch + cache, or return cache on failure
  [.returnCacheAndRevalidate]   → return cache; refresh stale data in background
  fetchResult                   → value + source + fetch timestamp; same-key network loads coalesce
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
MutationQueue.enqueueAndWait(request, key) → subscribe before enqueue → response or failure reason
```

### Cache Hierarchy

```
Cache<Value> (protocol: entry/setEntry/removeValue/removeAll)
  → InMemoryCache<T> (actor, O(1) LRU via LRUStorage)
  → LayeredCache<T> (actor, memory + optional persistent, ops serialized by CacheOperationGate)
  → SingleFlightCache<Wrapped> (actor, dedupes concurrent misses per key)
  → your disk cache (implement the four requirements)
RemoteDataCache<Wrapped: Cache<Data>> (actor, URL → Data, wraps SingleFlightCache)
```

### Key Design Points

- `NetworkEndpoint` is the request protocol; `TypedEndpoint` binds the response type for `APIClient.send(_:)`
- Keep `NetworkEndpoint.baseURL` required. For shared host/headers, refine the protocol and provide defaults in the
  refinement extension (see its DocC example); endpoints for CDNs and third parties can override them
- Endpoints may set `operationName` for low-cardinality instrumentation, `timeout`, `cachePolicy`, and
  `isIdempotent`; only opt a non-idempotent HTTP method in when the server guarantees safe replay
- `makeURLRequest()` is an extension on `NetworkEndpoint` in `NetworkEndpoint.swift` (standalone URL building)
- Use `any Cache<T>` for type erasure; there is no `AnyCache`. Never add a separate timestamp read:
  `entry(forKey:)` keeps the value and timestamp consistent
- `authRefreshDelay` applies `Task.sleep(for:)` before auth retry; use `authRefreshDelay: .zero` in tests
- `NetworkClientConfiguration.retryPolicy` is off by default; with it, idempotent requests retry on
  429/5xx/timeout/offline/server-unreachable (`NetworkClient.retryOrFail`). `GET`/`HEAD`/`PUT`/`DELETE`/`OPTIONS`
  are idempotent by default; endpoints can explicitly opt in or out. Use `NetworkRetryPolicy.immediate()` in tests
- 429 is `NetworkError.tooManyRequests(_:)`; other 4xx are `.clientError`, 5xx are `.serverError`, anything else is
  `.unexpectedStatus`. New status mappings go through `HTTPStatusValidator.error(for:)`
- On 401, or a provider-authorized 403 the provider opts in to, the client calls
  `AuthorizationProvider.refreshAuthorization(rejecting:)` with the exact
  provider authorization it sent, so providers can skip refreshing a token that was already replaced;
  it first asks `shouldRefreshAuthorization(after:)` (default `true` for 401, `false` for 403) so a provider can decline
- Every HTTP-derived `NetworkError` case carries a non-optional `HTTPResponse` (status, headers, body,
  `retryAfter`); only a transport `.timeout(nil)` has none. In tests build errors with `.status(_:retryAfter:body:)`
  from `Tests/SwiftyNetworkTests/Helpers`. Its `description` is redacted, but still never log the body.
  `HTTPResponse` parses `Retry-After` for 429 and 503 only
- Every exit from the request pipeline reports through `RequestTrace` (started/completed/failed/retried);
  add new exit paths through it rather than calling `NetworkInstrumentation` directly
- `NetworkError.transportError` is the single transport-error mapping for anything `URLSession` throws
  (public as `NetworkError.mapTransportError(_:session:)`): a `NetworkError` passes through; task cancellation,
  or a `URLError.cancelled` from a session with no delegate, becomes `CancellationError` (a `.cancelled` from a
  session with a delegate while the task is not cancelled, such as a rejected TLS pin, stays in `.underlying` and
  classifies as `.secureConnectionFailed`); connectivity-loss codes map to
  `.noInternetConnection`, host resolution/connection failures map to `.serverUnreachable` (both transient);
  other `URLError`s are kept intact in `.underlying`
- `Logger` messages are `@autoclosure`; don't pre-build strings or guard on `Logger.level` at call sites.
  The public knob is `LogLevel.current`; never set the level from a client or configuration
- `request(_:body:responseType:)` encodes `Encodable` bodies with config's encoder
- All actors use instance isolation -- no locks or GCD in production code
- `TestHTTPStub` uses TestCommons `TestValueBox` and `ScriptedValues` for synchronous response routing
- `MutationRequest` is `Codable` (not a closure) so a durable `MutationStore` can serialize
  "which endpoint plus what body" and replay it after relaunch. Its encoded form is a compatibility
  contract: bump `MutationRequest.version` for any change and keep decoding older versions
- `MutationRequest.authorization` is always `.none`; the queue's client authorizes through its provider.
  `AuthorizationType` is not `Codable` -- don't reintroduce persisted credentials. It persists
  `usesAuthorizationProvider` so an opted-out endpoint never gains credentials on replay
- `NetworkEndpoint.usesAuthorizationProvider` (default `true`) is the only way to keep the provider's
  credentials off an endpoint; `.none` alone means "use the provider". Wrapper endpoints such as
  `EncodedBodyEndpoint` must forward it
- `AuthorizationRefreshCoalescer` is the single refresh single-flight (`OAuthAuthorizationProvider` uses it).
  It checks reentrancy, then staleness (`isCurrentAuthorization`), then joins; a completed-flight counter
  re-checks staleness when a whole refresh finished during the check. The forced `refresh(_:)` never
  joins a flight that started before the call (it may predate the change being reacted to); it waits for
  it, then joins or starts the next one, keyed by a flight sequence number. It marks the running refresh with
  a task-local, so a refresh requested from inside it throws `ReentrantRefreshError` instead of joining
  (and waiting on) its own in-flight task
- `NetworkErrorCategory` and `MutationFailureReason.Category` must stay in step: 429 is `rateLimited`, TLS
  and pin failures (`secureConnectionFailed`, including a non-task `URLError.cancelled`) are `insecureConnection`
- Decoding `EmptyResponse` never reads the body (`NetworkClient` and `MockAPIClient`), so a plain-text 2xx succeeds
- `MutationQueue(waitForConnectivity:)`: an offline failure waits instead of consuming a retry and reports
  `.waitingForConnectivity`; the closure must return on cancellation. Success events carry the `HTTPResponse`
- `MutationQueue.enqueueAndWait` subscribes before enqueueing, returns the settled key's response, and throws
  `MutationFailureReason` for terminal failures. Finished statuses are bounded; keep terminal cleanup and replacement
  enqueue ordering under the per-key operations gate
- Coalescing correctness relies on `MutationStore.removeIfCurrent(_:for:)` being a single,
  non-suspending check-and-remove -- composing `load` then `remove` from outside reintroduces
  the race it exists to close

## Security

- Never commit API keys, tokens, credentials, or production URLs
- Inject auth via `AuthorizationProvider` -- never hardcode tokens
- Scrub sensitive headers before logging
- `Logger` marks URLs and underlying error descriptions private (error type/domain/code stay public); redact sensitive values before exporting diagnostics
- Validate URLs (scheme + host) in endpoints
- `MutationRequest` never captures authorization; headers and bodies are persisted as given, so a
  durable `MutationStore` implementation should still encrypt persisted mutations

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

## Conditional body readability

Short, obvious early exits may stay on one line (for example, `guard let self else { return }`).
Use multiline bodies for complex conditions, error construction, or meaningful work.
This is a review guideline; Apple’s official `swift format` remains the only formatting tool.
