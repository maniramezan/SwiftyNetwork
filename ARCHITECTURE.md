# SwiftyNetwork architecture

The package targets Swift 6 language mode, iOS 17+, and macOS 14+, with no
external dependencies. It has no package-wide main-actor default isolation or
upcoming-feature flags. `Package.swift` is the source of truth.

## Modules and boundaries

| Area | Implementation | Responsibility |
| --- | --- | --- |
| HTTP | `NetworkEndpoint.swift`, `APIClient.swift`, `NetworkClient.swift` | Describe, assemble, execute, validate, and decode requests |
| Configuration | `NetworkClientConfiguration.swift` | Session, JSON coders, auth provider, timeouts, instrumentation |
| Authentication | `AuthProvider.swift`, `AuthorizationType.swift` | Inject credentials and coalesce overlapping OAuth refreshes |
| TLS | `SSLPinningConfiguration.swift` | Optional certificate/SPKI pins with platform trust validation by default |
| Observation | `NetworkInstrumentation.swift`, `NetworkMonitor.swift`, `Logger.swift` | Request events, reachability, unified logging |
| Cache | `Cache.swift`, `AnyCache.swift`, `InMemoryCache.swift`, `LayeredCache.swift` | Storage protocols, type erasure, bounded memory, persistence composition |
| Fetch sharing | `SingleFlightCache.swift`, `RemoteDataCache.swift` | Coalesce same-key fetches; convenient remote-data caching |
| Repository | `Repository.swift` | Coordinate local and network sources using `CachePolicy` |
| Mutations | `Mutation/` | Retry, coalesce, persist, and observe background mutations |

## Request pipeline

`NetworkEndpoint` is the single endpoint protocol. `EndpointURLBuilder` validates
HTTP(S) scheme and host and assembles paths/query items. Standalone
`makeURLRequest()` and `NetworkClient` share header, method, and body assembly.
The standalone builder applies endpoint authorization; the client additionally
falls back to its provider when endpoint authorization is `.none`.

Each client call captures its configuration before suspension. It executes
`URLSession.data(for:)`, validates HTTP status, and decodes a `Decodable & Sendable`
result. `EmptyResponse` supports empty successful responses through the
`APIClient.request(_:)` convenience method, including protocol-based test doubles.
The encoded-body overload uses the configured encoder and preserves an explicitly
supplied Content-Type header.

A 401 can trigger provider refresh and replay up to `maxAuthRefreshAttempts`,
with `retryDelay` before replay. This is **not** general transient-error retry.
Endpoint-specific authorization does not trigger provider refresh. Attempt counts
include auth replays. Instrumentation callbacks are awaited and therefore add to
request latency; observers should do bounded work. Durations use `ContinuousClock`
and therefore remain unaffected by wall-clock corrections. They include authorization,
transport, and decoding, excluding the initial and terminal instrumentation callbacks.

## Concurrency and ownership

Actors protect mutable client, cache, OAuth, monitor, and mutation state.
`AnyCache` is a struct holding immutable `@Sendable` closures; its Sendable
conformance is compiler-checked. Cache protocols also support Sendable value
implementations. `GenericRepository` holds Sendable forwarding closures.

Actor isolation prevents data races, but an `await` allows another operation to
interleave. `SingleFlightCache` and `LayeredCache` serialize their storage operations across
awaits using an internal gate. Single-flight fetches run outside it and commit only
while their flight identity remains current. Access underlying storage exclusively
through the wrapper, and never call back into that wrapper from a storage method.
Individual operations are ordered; separate value/timestamp calls still do not
form a transaction. See [the review backlog](REVIEW.md) for remaining contracts.

Shared OAuth refreshes and single-flight fetches use owned unstructured tasks
because multiple independent callers share their lifetime. Mutation workers must
outlive enqueue calls. Reachability and URLSession delegate callbacks require
bridges from synchronous platform APIs. The synchronous logger uses
`OSAllocatedUnfairLock` for its process-wide log level; URLProtocol tests use
`NSLock` for synchronous callback state. These are existing interoperability
exceptions, not a pattern for new async APIs.

## Cache and repository flow

`Cache` provides values and timestamps. `TimestampedCache` adds explicit timestamp
writes. `PersistentCache` is a marker; apps implement actual persistence.
`InMemoryCache` updates LRU access times on reads and scans entries on eviction
(O(n)); expiration scans storage too. `LayeredCache` reads memory first and promotes
persistent values, preserving an available timestamp.

Repositories implement cache-first, reload, and maximum-age policies. Their read
and timestamp calls are separate operations. Cache keys must identify the user,
resource, and all request inputs that affect the result. Clear sensitive caches
on logout. `SingleFlightCache` adds fetch sharing, not an atomic transaction API.

## Mutation lifecycle

`MutationQueue.enqueue` saves a Codable `MutationRequest`, then starts background
work per `MutationKey`. Replacing the same key coalesces pending work. Workers
retry transient failures according to `MutationRetryPolicy`, publish status, and
conditionally remove completed requests using `MutationStore.removeIfCurrent`.
That comparison and removal must be one atomic operation in custom stores.

Persistence does not provide exactly-once delivery. Servers must enforce
idempotency for operations that may be replayed. Durable stores must encrypt
captured credentials and sensitive bodies. The default store is memory-only.

## Security boundaries

TLS pinning applies only to configured hosts. Exact policies win; otherwise the
nearest ancestor permitting subdomains wins. Unlisted hosts use system trust.
Pinning is not a host allowlist or redirect policy. Keep default trust validation
enabled and plan overlapping pins for rotation.

Logs use `os.Logger`, including in release builds, and default to warning level.
URLs and underlying errors are marked private, not structurally scrubbed.
Instrumentation and error values can contain sensitive URLs and response bodies;
applications must redact before exporting them. Use HTTPS for sensitive traffic,
limit credentialed clients to trusted endpoints, and configure URLSession redirect
handling when using custom authentication headers. See [SECURITY.md](SECURITY.md).

## Extension points

Prefer `any APIClient` in services and `NetworkDataSource` for repositories.
Provide custom `AuthorizationProvider`, `Cache`, `MutationStore`, and
`NetworkInstrumentation` implementations at the relevant boundary. See
[README.md](README.md) for integration and [GRAPHQL.md](GRAPHQL.md) for GraphQL.
Avoid raising deployment targets or adding dependencies without a demonstrated
consumer requirement. See [CONTRIBUTING.md](CONTRIBUTING.md) for validation commands.
