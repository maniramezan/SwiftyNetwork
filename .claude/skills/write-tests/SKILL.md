---
name: write-tests
description: Write or review Swift Testing tests for SwiftyNetwork using the repo's helpers (TestURLProtocol, Gate, FakeAPIClient, MockAPIClient, FakeNetworkInstrumentation). Use when adding tests, fixing flaky tests, or reviewing test changes.
---

# Writing SwiftyNetwork tests

Framework: Swift Testing (`import Testing`, `@Test`, `@Suite`, `#expect`, `#require`).
Tests live in `Tests/SwiftyNetworkTests/<Area>/<TypeName>Tests.swift`.

## Pick the right seam

| Code under test | Use |
|---|---|
| `NetworkClient` request pipeline, headers, status mapping, auth refresh | `makeTestSession()` + `TestURLProtocol` with a unique `makeEndpointWithTestId("...")` per test |
| Anything that only needs an `APIClient` (MutationQueue, repositories, services) | `MockAPIClient` from `SwiftyNetworkTesting` |
| MutationQueue races (supersede while in flight, etc.) | `FakeAPIClient(outcomes:gatesByCallIndex:)` + `Gate` |
| Instrumentation events | `FakeNetworkInstrumentation` |
| Auth refresh | `TestAuthorizationProvider` (records `refreshCallCount`, `rejectedAuthorizations`) |
| Pure logic (`LRUStorage`, `CachePolicy`, `MutationRetryPolicy.delay`) | Direct unit tests, inject `jitterGenerator` |

## Rules

- **Isolation over serialization.** Every test builds its own client/cache/queue
  and uses a unique `test-id`. Add `.serialized` only for truly global state
  (for example `Logger.setLevel`).
- **No timing-based synchronization.** Never `Task.sleep` to "let something
  happen". Use `Gate`, `CacheOperationGate.queuedOperationCount`, or await an event
  from a stream (`firstEvent(in:where:)`, `collectEvents(_:count:)`) -- both are
  bounded so a failure can't hang the suite.
- Use `retryDelay: 0` for `NetworkClientConfiguration` and
  `MutationRetryPolicy.immediate()` (or `baseDelay: 0`) for queues.
- `#expect(throws: SomeError.self)` for expected errors; `#require` for
  prerequisites; `Issue.record` only for unreachable branches.
- Hoist mutating calls on local `var`s out of `#expect`/`#require` into a `let`
  first -- the macros may capture operands in closures.
- Compare optionals of non-`Equatable` types via an `Equatable` projection
  (`result?.key == nil`) rather than `== nil` on the tuple/struct.
- Subscribe to `MutationQueue.events()` **before** `enqueue` if you assert on `.pending`.
- Name tests with a behavior sentence: `@Test("Upward jitter never pushes the delay past maxDelay")`.

## Checklist per change

- Success path, each failure mapping, and the boundary values (empty body,
  `maxSize: 0`, `maxAttempts: 0`, negative inputs clamped).
- Cancellation: a canceled caller and a canceled shared task.
- Regression test that fails on the old code for every bug fix.
