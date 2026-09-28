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

## Follow-ups with open pull requests

| Finding | Pull request |
| --- | --- |
| `MutationQueue` couldn't cancel a pending key or clear everything on sign-out | maniramezan/SwiftyNetwork#17 (`cancel(_:)`, `cancelAll()`, `MutationFailureReason.isCancellation`) |
| `RemoteDataCache` mapped every non-2xx status to `serverError` | maniramezan/SwiftyNetwork#18 (shares `HTTPStatusValidator`; migration notes in the PR) |
| JSON encoding/decoding ran on the client actor | maniramezan/SwiftyNetwork#19 (nonisolated static helpers; not benchmarked) |
| Entry count didn't bound bytes in `RemoteDataCache` | maniramezan/SwiftyNetwork#20 (`InMemoryCache(maxCost:cost:)`, `InMemoryCache<Data>(maxBytes:)`) |
| `SwiftyNetworkTesting` had no DocC | maniramezan/SwiftyNetwork#21 (catalog, Docs CI validation, `.spi.yml`) |

## Priority follow-ups

These findings come from source inspection; they are not claims of a complete
security audit or measured performance gains.

| Priority | Finding | Proposed change and acceptance criteria |
| --- | --- | --- |
| High | Credentialed requests accept arbitrary endpoint hosts and URLSession redirects; pinning applies only to listed hosts. | Design an opt-in allowed-origin and redirect policy covering custom API-key headers, scheme downgrade, and injected sessions. Test with a local redirect server. |
| Medium | GraphQL error bodies and headers cannot always be recovered after HTTP mapping. | Add a raw response abstraction preserving status, headers, and data; layer typed decoding on it. Use that boundary for GraphQL errors, Retry-After, ETags, and content-type validation. Preserve current typed API behavior. |
| Medium | Repositories read values and timestamps separately; concurrent requests are not coalesced at the repository boundary. | Explore atomic cache-entry reads and explicit repository fetch sharing without conflating cache policies or users. |
| Medium | Mutable JSON coders and sessions are reference-backed despite configuration snapshot wording. | Document ownership and prohibit concurrent external coder reconfiguration; evaluate factory-based configuration in an API proposal. |
| Low | Some public instrumentation/cache members lack full DocC parameter documentation; examples are not systematically compiled. | Add documentation compilation checks and external-consumer API fixtures to CI; avoid packaging-only tests that duplicate implementation. |

## Evolution constraints

Keep Swift 6.0 and the current deployment targets until a concrete requirement
justifies a migration. Prefer additive protocol conveniences and shared internal
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
Serialization covers all keys, so slow storage creates head-of-line blocking;
per-key storage queues with a global removeAll barrier are a possible measured
optimization, not required for correctness. Separate value/timestamp API calls
still do not form an atomic snapshot for repository consumers.

Cache-fix validation: the full suite ran 180 tests with 177 passing and the same
three previously reproduced TLS failures. After adding the independent-key fetch
regression, all seven ordering tests passed (including parameterized invalidation
and layered-removal cases). The release build, strict formatting, and diff checks
passed. No performance improvement is claimed for the storage serialization change.

Monotonic timing batch: request event durations now use ContinuousClock, preserving
the public TimeInterval representation and documenting measured pipeline boundaries.
