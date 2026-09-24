---
name: add-component
description: Add a new public component (type, protocol, cache, client feature, or test double) to SwiftyNetwork end to end -- placement, API shape, DocC, tests, and docs. Use whenever a change introduces a new public type or a new file under Sources/.
---

# Adding a component to SwiftyNetwork

SwiftyNetwork is a shared-components library: every public symbol is a long-term
commitment for every app that depends on it. Follow these steps in order.

## 1. Decide whether it belongs here

- It must be reusable across apps and have no app-specific assumptions.
- No new package dependencies (`Package.swift` stays dependency-free). Test doubles
  go in the `SwiftyNetworkTesting` target, never in `SwiftyNetwork`.
- Check REVIEW.md "Evolution constraints" and PLAN.md's checklist first.
- Prefer composing existing primitives (`Cache`, `SingleFlightCache`,
  `CacheOperationGate`, `LRUStorage`, `RequestTrace`, `HTTPStatusValidator`,
  `NetworkError.mapURLError`) over re-implementing them.

## 2. Place it

| Kind | Location |
|---|---|
| HTTP pipeline / auth / TLS / observation | `Sources/SwiftyNetwork/Network/` |
| Cache types and cache helpers | `Sources/SwiftyNetwork/Cache/` |
| Repository coordination | `Sources/SwiftyNetwork/Repository/` |
| Mutation queue pieces | `Sources/SwiftyNetwork/Mutation/` |
| Public fakes/mocks for consumers | `Sources/SwiftyNetworkTesting/` |

One primary type per file; file name = type name. Split internal helpers into
their own files (see `HTTPStatusValidator.swift`, `RequestTrace.swift`, `LRUStorage.swift`).

## 3. Shape the API

- `Sendable` everywhere. Shared mutable state lives in an `actor`; pure logic is a
  value type or a caseless `enum` namespace (internal unless consumers need it).
- Additive changes only. Adding a case to a public enum or a requirement to a
  public protocol is **source-breaking** -- give new protocol requirements a
  default implementation in an extension (see `refreshAuthorization(rejecting:)`).
- Map transport errors with `NetworkError.mapURLError`; map statuses with
  `HTTPStatusValidator`; classify retryability with `NetworkError.isTransient`.
- Log through `Logger` with the right `Category`; never log tokens, bodies, or
  unredacted URLs (use `Logger.debugURL`).
- Public value types that apps may need to fabricate in tests need a public `init`.

## 4. Document

- `///` DocC on every public symbol: summary, `- Parameters:`, `- Returns:`,
  `- Throws:`, and a short ```` ```swift ```` example for non-trivial APIs.
- New top-level public types in `SwiftyNetwork` must be curated under a Topics
  heading in `Sources/SwiftyNetwork/SwiftyNetwork.docc/SwiftyNetwork.md`
  (the Docs workflow runs with `--warnings-as-errors`; double-backtick links
  must resolve).
- Update README.md (usage section), AGENTS.md (project tree + key design points),
  and ARCHITECTURE.md (module table) when the component is user-visible.

## 5. Test

Load the `write-tests` skill. Cover success, failure, cancellation, and any
concurrency ordering guarantee the component documents.

## 6. Verify

Load the `pre-push-check` skill before committing.
