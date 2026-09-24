---
name: concurrency-review
description: Review or implement actor/async code in SwiftyNetwork against the repo's concurrency invariants (actor reentrancy, CacheOperationGate ordering, single-flight identity, unstructured task ownership, AsyncStream registration). Use when touching actors, Task {}, AsyncStream, continuations, or cache/mutation ordering.
---

# Concurrency review for SwiftyNetwork

The package builds in Swift 6 language mode with strict concurrency. The compiler
proves data-race freedom; it does **not** prove ordering. Review for these.

## Actor reentrancy

- State read before an `await` may be stale after it. Re-check after every
  suspension (see `SingleFlightCache.commit` comparing flight `id`, and
  `MutationStore.removeIfCurrent`).
- Compound cache operations (read + promote, invalidate + write) must run inside
  `operations.run { ... }` of the wrapper's `CacheOperationGate`. Never call back
  into the same wrapper from inside the gate (deadlock), and keep network fetches
  **outside** the gate so invalidation can cancel them.

## Unstructured tasks

Allowed only where independent callers share a lifetime or work must outlive the
caller: OAuth refresh coalescing, single-flight fetches, `MutationQueue` workers,
bridges from synchronous platform callbacks. For each `Task {}` check:

- Who cancels it, and what observes cancellation?
- Does it capture `self` strongly on purpose (in-flight work) or weakly (observers)?
- **Ordering**: never spawn one `Task` per callback to forward events -- tasks can
  run out of order. Yield into a single `AsyncStream` and consume it with one task
  (see `NetworkMonitor.startMonitoring`).

## AsyncStream

- Create with `AsyncStream.makeStream(...)` and register the continuation
  synchronously on the actor before returning the stream. Deferring
  registration to a `Task` lets `onTermination` run first and leak it.
- Pick a buffering policy deliberately: state streams (reachability) use
  `.bufferingNewest(1)`; event logs (mutation events) stay unbounded.
- `onTermination` is `@Sendable` and nonisolated: hop back with
  `Task { await self?.unregister(id) }`.

## Locks and GCD

Not in new code. The existing exceptions are `Logger` (`OSAllocatedUnfairLock`,
synchronous API), `NWPathMonitor`'s dispatch queue, and `TestURLProtocolState`
(`NSLock`, synchronous `URLProtocol`). Any new `@unchecked Sendable` needs a
written safety invariant next to it.

## Cancellation

- `Task.sleep` throws on cancellation: report the attempt's outcome before
  rethrowing (see `NetworkClient.handleUnauthorized` + `RequestTrace.failed`).
- A canceled caller must not cancel shared work (`SingleFlightCache`,
  OAuth refresh); it observes `CancellationError` after the shared work ends.

## Output

For each finding give: file:line, the interleaving that breaks (step by step),
the observable symptom, and the minimal fix. Add a regression test that forces
the interleaving with `Gate`s, not sleeps.
