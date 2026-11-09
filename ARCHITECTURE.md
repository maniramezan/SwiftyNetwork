# SwiftyNetwork architecture

The package uses Swift 6.2 tooling and Swift 6 language mode, iOS 18+, and macOS 15+,
with SwiftCommons for shared utilities (default traits disabled, imported with
`internal import` so it never becomes part of the public API). It has no
package-wide main-actor default isolation or upcoming-feature flags. `Package.swift` is the source of truth.

## Modules and boundaries

| Area | Implementation | Responsibility |
| --- | --- | --- |
| HTTP | `NetworkEndpoint.swift`, `APIClient.swift`, `NetworkClient.swift` | Describe, assemble, execute, validate, and decode requests |
| Configuration | `NetworkClientConfiguration.swift` | Session, JSON coders, auth provider, retry and redirect policies, timeouts, instrumentation |
| Authentication | `AuthProvider.swift`, `AuthorizationType.swift` | Inject credentials and coalesce overlapping OAuth refreshes |
| TLS | `SSLPinningConfiguration.swift` | Optional certificate/SPKI pins with platform trust validation by default |
| Redirects | `RedirectPolicy.swift`, `RedirectGuard.swift` | Strip credentials on cross-origin redirects and refuse HTTPS downgrades, through a per-task delegate |
| Observation | `NetworkInstrumentation.swift`, `NetworkMonitor.swift`, `Logger.swift` | Request events, reachability, unified logging |
| Cache | `Cache.swift`, `InMemoryCache.swift`, `LayeredCache.swift` | `Cache<Value>` protocol and `CacheEntry`, bounded memory, persistence composition |
| Fetch sharing | `SingleFlightCache.swift`, `RemoteDataCache.swift` | Coalesce same-key fetches; convenient remote-data caching |
| Repository | `Repository.swift` | Coordinate a cache and the network using `CachePolicy` |
| Mutations | `Mutation/` | Retry, coalesce, persist, and observe background mutations |
| Test doubles | `Sources/SwiftyNetworkTesting/` (separate product) | `MockAPIClient`, `RecordedRequest`, `MutationRetryPolicy.immediate()`, `NetworkRetryPolicy.immediate()` |

Internal building blocks are kept in their own files so they can be reused and
tested directly: `HTTPStatusValidator` (status → `NetworkError`), `RequestTrace`
(one instrumentation event per pipeline exit), `EncodedBodyEndpoint`/`HTTPHeaders`
(JSON body + Content-Type defaulting shared with `MutationRequest`),
`LRUStorage` (O(1) LRU used by `InMemoryCache`), and
`CacheOperationGate` (FIFO ordering for compound cache operations).

SwiftCommons supplies `AnySendableError`, `AsyncBroadcaster`, `RetryBackoff`,
`LibraryLogger`, suffix trimming, and duration conversion. Swift’s standard
prefix trimming and SwiftCommons’ suffix trimming normalize endpoint paths.

## Request pipeline

`NetworkEndpoint` is the single endpoint protocol. `EndpointURLBuilder` validates
HTTP(S) scheme and host and assembles paths/query items. Standalone
`makeURLRequest()` and `NetworkClient` share header, method, and body assembly.
The standalone builder applies endpoint authorization; the client additionally
falls back to its provider when endpoint authorization is `.none` and the endpoint's
`usesAuthorizationProvider` is `true` (the default). If the provider
throws, the request fails with `authorizationUnavailable` and is never sent.

Each client call captures its configuration before suspension. It executes
`URLSession.data(for:)`, validates HTTP status, and decodes a `Decodable & Sendable`
result into a `DecodedResponse` that also carries the `HTTPResponse`. `APIClient`
has one decoding requirement, `response(for:responseType:)`; every `request` method is
a protocol-extension convenience over it. Decoding `Data` returns the raw body, and
`EmptyResponse` ignores the body of any successful response, including in protocol-based test doubles.
The encoded-body overload uses the configured encoder and preserves an explicitly
supplied Content-Type header.

`sendAuthorized(_:errorBody:transport:)` runs this same 401 flow (`refreshAfterUnauthorized`) around a
caller-supplied transport for requests `NetworkClient` cannot decode, such as streams. It reuses the redirect guard and
instrumentation, maps statuses with `HTTPStatusValidator`, and does not apply `retryPolicy`. Its work ends at the
response headers; callers map later stream errors with `NetworkError.mapTransportError(_:)`. It applies provider
credentials to any URL, so it is for the app's own API only.

A 401 can trigger provider refresh and replay up to `maxAuthRefreshAttempts`,
with `authRefreshDelay` before replay. The client passes the exact provider authorization
it sent to `refreshAuthorization(rejecting:)`, so `OAuthAuthorizationProvider`
skips refreshing a token that a concurrent request already replaced. Before refreshing, the client also asks
`shouldRefreshAuthorization(after:)` (default `true`) with the `401` response, so a provider can decline for a
`401` that a new token cannot fix. Every non-2xx error (`401`, `403`, `404`, `408`, `429`, 5xx, ...) carries an `HTTPResponse`
(status, headers, body), exposed as `NetworkError.response`; `403` never triggers a refresh. Neither is general transient-error retry;
that is the opt-in `NetworkRetryPolicy` (`NetworkClientConfiguration.retryPolicy`, off by default), which `performRequest`
consults through `retryOrFail` after any failed attempt. It retries `GET`/`HEAD`/`PUT`/`DELETE` only, on 429, 5xx,
timeout and lost connectivity, with capped jittered backoff and a clamped `Retry-After`. Refresh and policy retries
have independent budgets (`refreshAttempt`, `retryAttempt`). `HTTPStatusValidator` maps 429 to
`NetworkError.tooManyRequests`, other 4xx to `.clientError`, and 5xx to `.serverError`; `HTTPResponse` parses
`Retry-After` (delta-seconds and HTTP-date) for 429 and 503.
Endpoint-specific authorization does not trigger provider refresh. Attempt counts
include auth replays. Instrumentation callbacks are awaited and therefore add to
request latency; observers should do bounded work. Durations use `ContinuousClock`
and therefore remain unaffected by wall-clock corrections. They include authorization,
transport, and decoding, excluding the initial and terminal instrumentation callbacks.

## Concurrency and ownership

Actors protect mutable client, cache, OAuth, monitor, and mutation state.
`Cache` has a primary associated type, so `LayeredCache` and `GenericRepository`
store `any Cache<Value>` existentials instead of hand-written type erasure. Cache
protocols also support Sendable value implementations.

`NetworkMonitor` forwards path updates through one ordered stream and registers
each `updates` continuation synchronously on the actor.

Actor isolation prevents data races, but an `await` allows another operation to
interleave. `SingleFlightCache` and `LayeredCache` serialize their storage operations across
awaits using an internal gate. Single-flight fetches run outside it and commit only
while their flight identity remains current. Access underlying storage exclusively
through the wrapper, and never call back into that wrapper from a storage method.
Individual operations are ordered, and `entry(forKey:)` returns a value and its
timestamp as one snapshot. See [the review backlog](REVIEW.md) for remaining contracts.

Shared OAuth refreshes and single-flight fetches use owned unstructured tasks
because multiple independent callers share their lifetime. Mutation workers must
outlive enqueue calls. Reachability and URLSession delegate callbacks require
bridges from synchronous platform APIs. The synchronous logger uses
`OSAllocatedUnfairLock` for its process-wide log level; URLProtocol tests use
`NSLock` for synchronous callback state. These are existing interoperability
exceptions, not a pattern for new async APIs.

## Cache and repository flow

`Cache` reads and writes whole `CacheEntry` values (value plus timestamp);
`value(forKey:)` and `setValue(_:forKey:)` are protocol-extension conveniences.
Apps implement persistence as an ordinary `Cache`.
`InMemoryCache` keeps entries in `LRUStorage`, so reads, writes, and eviction are
O(1) and eviction order is deterministic; age-based expiration scans storage (O(n)). `LayeredCache` reads memory first and promotes
persistent entries with their original timestamp.

Repositories implement cache-first, reload, and maximum-age policies. Their read
and timestamp calls are separate operations. Cache keys must identify the user,
resource, and all request inputs that affect the result. Clear sensitive caches
on logout. `SingleFlightCache` adds fetch sharing, not an atomic transaction API.

## Mutation lifecycle

`MutationQueue.enqueue` saves a Codable, versioned `MutationRequest` (no credentials;
the queue's client authorizes each attempt through its provider), then starts background
work per `MutationKey`. Replacing the same key coalesces pending work. Workers
retry transient failures according to `MutationRetryPolicy`, publish status, and
conditionally remove completed requests using `MutationStore.removeIfCurrent`.
That comparison and removal must be one atomic operation in custom stores.

Persistence does not provide exactly-once delivery. Servers must enforce
idempotency for operations that may be replayed; `MutationRequest.addingIdempotencyKey(_:header:)`
stores a key in the persisted headers so every replay sends the same one. With `waitForConnectivity`,
an offline failure waits for the closure instead of consuming a retry, so durable mutations survive
long offline periods. Mutations for different keys are independent and unordered. Durable stores must encrypt
captured credentials and sensitive bodies. The default store is memory-only.

## Security boundaries

TLS pinning applies only to configured hosts. Exact policies win; otherwise the
nearest ancestor permitting subdomains wins. Unlisted hosts use system trust.
Pinning is not a host allowlist. Keep default trust validation enabled and plan
overlapping pins for rotation.

`RedirectPolicy.stripCredentialsAcrossOrigins` (the default) runs as a per-task
`URLSessionTaskDelegate` passed to `data(for:delegate:)`, so it applies to injected
and pinned sessions alike; the session delegate still answers trust challenges.
A redirect to another origin (scheme, host, effective port, compared to the URL the
caller requested) loses `Authorization`, `Proxy-Authorization`, `Cookie`, and the
applied `AuthorizationType`'s header. An `https` to `http` redirect is refused and
surfaces as `unexpectedStatus` with the `3xx`. `.followAll` installs no delegate.
A task delegate takes precedence over the session delegate, so the guard forwards
each redirect to a session delegate that implements the redirect callback and
returns its answer unchanged: the app's own redirect handling always decides. The
guard uses the completion-handler callback so it runs on the session's delegate queue.

Logs use `os.Logger`, including in release builds, and default to warning level. The level is package-wide
(`LogLevel.current`); configurations do not carry one, so creating a client never changes logging.
URLs and underlying errors are marked private, not structurally scrubbed.
Instrumentation and error values can contain sensitive URLs and response bodies;
applications must redact before exporting them. Use HTTPS for sensitive traffic,
limit credentialed clients to trusted endpoints, and send credentials through an
`AuthorizationType` rather than ad hoc endpoint headers so cross-origin redirects
strip them. See [SECURITY.md](SECURITY.md).

## Extension points

Depend on `any APIClient` in services, repositories, and mutation queues.
Provide custom `AuthorizationProvider`, `Cache`, `MutationStore`, and
`NetworkInstrumentation` implementations at the relevant boundary. See
[README.md](README.md) for integration and [GRAPHQL.md](GRAPHQL.md) for GraphQL.
Avoid raising deployment targets or adding dependencies without a demonstrated
consumer requirement. See [CONTRIBUTING.md](CONTRIBUTING.md) for validation commands.
