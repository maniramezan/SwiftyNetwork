# Repository review

## Implemented in this review

- Deterministic TLS policy specificity, with regression coverage.
- Shared request construction and protocol-level empty-response convenience.
- Repeated leading path slash normalization matching the documented contract.
- Current architecture, GraphQL recipe, security boundaries, and migration notes.
- Removed README commands for formatter plugins absent from Package.swift.
- Serialized compound cache operations, fenced single-flight completion by identity,
  and invalidated pending fetches on explicit writes and removals. Regression tests
  use gates and queue admission checks to force suspended commits/promotions.

## Implemented in the components review

- `NetworkError.mapURLError` maps connection-lost, cellular-data-disabled, and
  roaming-off codes to `.noInternetConnection`, so `MutationQueue` retries them;
  other `URLError`s stay inspectable inside `.underlying`.
- `AuthorizationProvider.refreshAuthorization(rejecting:)` (defaulted) lets
  `OAuthAuthorizationProvider` skip refreshing a token another request already
  replaced, which avoids consuming rotating refresh tokens twice. Added
  `updateAccessToken(_:)`.
- `MutationRetryPolicy.delay` now honors `maxDelay` after jitter.
- `NetworkMonitor` applies path updates in order through one stream and registers
  `updates` continuations synchronously (no leaked continuations; newest-only buffering).
- `NetworkClient` reports cancellation during the auth-retry delay to instrumentation.
- `InMemoryCache` uses the new O(1) `LRUStorage`, with deterministic eviction and negative sizes clamped.
- `Logger` builds messages lazily and reuses one `os.Logger` per category.
- SSL pinning skips SPKI reconstruction when a policy has no public-key pins.
- Split `NetworkClient` helpers into `HTTPStatusValidator`, `RequestTrace`,
  `EncodedBodyEndpoint`/`HTTPHeaders`, and `AnySendableError`; `MutationRequest`
  shares the Content-Type helper.
- Added the `SwiftyNetworkTesting` product (`MockAPIClient`, `RecordedRequest`,
  `MutationRetryPolicy.immediate()`), `CacheKey` string literals, a public
  `MutationQueue.MutationEvent` initializer, and repo agent skills in `.claude/skills/`.

These changes were authored without a local Swift toolchain (the sandbox could
not download one), so their only validation is the PR's GitHub Actions run.

## Implemented for the 2.0 consumer migration

- Map DNS lookup and connection-refused failures to transient
  `NetworkError.serverUnreachable`.
- Keep `NetworkEndpoint.baseURL` required and document shared defaults via protocol refinements.
- Add `operationName`, per-endpoint timeout/cache policy, and endpoint idempotency; let providers
  opt into refresh for provider-authorized legacy `403` responses.
- Add typed endpoints, max-age single-flight reads, network-first cache fallback, stale-while-revalidate,
  repository result source/timestamp metadata, and same-key network fetch coalescing.
- Add built-in `DiskCache` and `FileMutationStore`, `MutationQueue.enqueueAndWait`, successful
  response events, bounded finished statuses, and deterministic coverage for the terminal-removal race.

## Completed follow-ups

| Finding | Pull request |
| --- | --- |
| `MutationQueue` couldn't cancel a pending key or clear everything on sign-out | maniramezan/SwiftyNetwork#17 (`cancel(_:)`, `cancelAll()`, `MutationFailureReason.isCancellation`) |
| `RemoteDataCache` mapped every non-2xx status to `serverError` | maniramezan/SwiftyNetwork#18 (shares `HTTPStatusValidator`; migration notes in the PR) |
| JSON encoding/decoding ran on the client actor | maniramezan/SwiftyNetwork#19 (nonisolated static helpers; not benchmarked) |
| Entry count didn't bound bytes in `RemoteDataCache` | maniramezan/SwiftyNetwork#20 (`InMemoryCache(maxCost:cost:)`, `InMemoryCache<Data>(maxBytes:)`) |
| `SwiftyNetworkTesting` had no DocC | maniramezan/SwiftyNetwork#21 (catalog, Docs CI validation, `.spi.yml`) |
| Credentialed requests followed redirects to any host with their headers | `RedirectPolicy`, default `.stripCredentialsAcrossOrigins` (strips credentials across origins, refuses HTTPS downgrades; per-task delegate so injected and pinned sessions are covered, while a session delegate that handles redirects keeps deciding them) |
| In Xcode apps with dynamic frameworks, `SwiftyNetworkTesting` embedded a second copy of `SwiftyNetwork`, breaking error casts and retroactive conformances | Removed the product; its doubles moved into `SwiftyNetwork` as `@_spi(Testing)` API. `Tests/XcodeIntegration/verify.sh` passes, and its test bundle defines no SwiftyNetwork symbols |
| SwiftCommons 0.17.0's `AsyncBroadcaster` (behind `MutationQueue.events()` and `NetworkMonitor`) deadlocked when a consumer was cancelled while a value was yielded, which hung the iOS test process in CI | maniramezan/SwiftCommons#56 (released in 0.17.1); SwiftyNetwork now requires `from: "0.17.1"` |
| Mutable JSON coders and sessions are reference-backed despite configuration snapshot wording | Documented coder ownership and prohibited concurrent external coder reconfiguration post-initialization in `NetworkClientConfiguration` |

## Priority follow-ups

These findings come from source inspection; they are not claims of a complete
security audit or measured performance gains.

| Priority | Finding | Proposed change and acceptance criteria |
| --- | --- | --- |
| Medium | The 2.0 audits were source-level; the gaps found by migrating a real app (raw/streaming transports, error categories, migration-guide holes, fixture overlap) were only visible from a consumer. A consumer-side review then found more: no per-endpoint opt-out of the provider (and a refresh-handler deadlock), offline mutations dropped from durable stores, mutation responses discarded, plain-text 2xx bodies failing `EmptyResponse`, no idempotency-key support, 429 and TLS failures miscategorized, and a case-colliding disk-cache recipe. All are fixed on `feature/pre-2.0-consumer-gaps`. | Before each major tag, migrate one real consumer app onto the release candidate, ideally one that uses `MutationQueue` with a durable store, and fold its friction into the API and `MigratingTo*.md`; keep adding external-consumer fixtures. |
| Medium | `LayeredCache` and `SingleFlightCache` serialize storage operations across keys. The Novalingo image-grid workload has not been measured. | Keep the current ordering guarantees; benchmark the consumer workload before adding per-key storage concurrency. |
| Low | A non-task `URLError.cancelled` is treated as a TLS/authentication-challenge failure when the supplied session has a delegate. A session invalidation with a delegate may be misclassified the same way. | Model the session/task cancellation source before changing this classification; keep it separate from task cancellation and pin rejection. |
| Low | Some public instrumentation/cache members lack full DocC parameter documentation; examples are not systematically compiled. | Add documentation compilation checks and external-consumer API fixtures to CI; avoid packaging-only tests that duplicate implementation. |

## Evolution constraints

SwiftCommons adoption requires Swift 6.2 tooling. Keep the current deployment
targets unless a concrete requirement justifies a migration. Prefer additive protocol conveniences and shared internal
primitives. Avoid typed throws while injected transports can throw arbitrary
errors. Do not add a GraphQL runtime dependency solely to transport JSON; schema
code generation and subscription support merit separate design proposals.

Before changing retries, distinguish HTTP auth replay from mutation retries and
require idempotency semantics. Before changing caching, write down invalidation,
account isolation, cancellation, and persistence ordering guarantees.

## Validation

The full edited suite ran 174 tests: 171 passed and three existing TLS tests
failed. The same three failures reproduced on an unchanged HEAD checkout:
two `SecKeyCreateRandomKey` failures and one anchored certificate trust failure.
All six added regression tests passed. Strict swift-format lint and
`git diff --check` passed. Build caches were redirected to `/tmp` and SwiftPM's
nested sandbox disabled to run within the workspace's existing restrictions.
The full suite still needs a clean run on a host with working Security services;
this review does not establish live TLS handshake or redirect behavior.

## Cache ordering contract

`SingleFlightCache` and `LayeredCache` now queue storage operations across awaits.
Single-flight network fetches remain concurrent across keys and run outside the
storage gate. Explicit writes/removals cancel and invalidate the affected flight;
late completions cannot clear replacement flights or overwrite their values.
All callers sharing a flight await its cache commit before returning.

A canceled caller does not cancel the shared fetch and observes cancellation when
that work finishes. Cancellation does not bypass a queued storage mutation.
Use wrapped caches exclusively through their wrapper; direct mutations bypass
these guarantees. Custom storage must not recursively call the same wrapper.
Serialization covers all keys, so slow storage creates head-of-line blocking.
Per-key storage queues with a global removeAll barrier are a possible optimization,
but should wait for a benchmark of the image-grid workload. `entry(forKey:)` returns
a value and its timestamp as one snapshot for repository consumers.

Cache-fix validation: the full suite ran 180 tests with 177 passing and the same
three previously reproduced TLS failures. After adding the independent-key fetch
regression, all seven ordering tests passed (including parameterized invalidation
and layered-removal cases). The release build, strict formatting, and diff checks
passed. No performance improvement is claimed for the storage serialization change.

Monotonic timing batch: request event durations use ContinuousClock and are exposed
as `Duration`, documenting measured pipeline boundaries.
