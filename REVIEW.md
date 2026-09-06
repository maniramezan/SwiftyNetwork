# Repository review

## Implemented in this review

- Deterministic TLS policy specificity, with regression coverage.
- Shared request construction and protocol-level empty-response convenience.
- Repeated leading path slash normalization matching the documented contract.
- Current architecture, GraphQL recipe, security boundaries, and migration notes.
- Removed README commands for formatter plugins absent from Package.swift.

## Priority follow-ups

These findings come from source inspection; they are not claims of a complete
security audit or measured performance gains.

| Priority | Finding | Proposed change and acceptance criteria |
| --- | --- | --- |
| High | Single-flight invalidation and layered promotion can race across awaits. | Serialize compound storage operations and fence late fetch completions by identity; test suspended commits, replacement flights, and removals. |
| High | Credentialed requests accept arbitrary endpoint hosts and URLSession redirects; pinning applies only to listed hosts. | Design an opt-in allowed-origin and redirect policy covering custom API-key headers, scheme downgrade, and injected sessions. Test with a local redirect server. |
| Medium | GraphQL error bodies and headers cannot always be recovered after HTTP mapping. | Add a raw response abstraction preserving status, headers, and data; layer typed decoding on it. Use that boundary for GraphQL errors, Retry-After, ETags, and content-type validation. Preserve current typed API behavior. |
| Medium | `NetworkClient` durations use wall-clock Date; synchronous JSON encoding/decoding runs on its actor. | Use a monotonic clock for elapsed durations. Benchmark concurrent large payloads before moving decoding to a separate executor or introducing coder factories. |
| Medium | LRU eviction scans all entries and relies on Date ordering; entry count does not bound bytes in `RemoteDataCache`. | Benchmark realistic cache sizes; consider a sequence-based access order, O(1) LRU structure, and optional byte-cost limits based on evidence. |
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
