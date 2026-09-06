# Changelog

## Unreleased

- Prevent invalidated single-flight fetches from repopulating storage or clearing replacements.
- Make explicit cache writes supersede pending fetches; canceled callers leave shared work running.
- Serialize layered promotion, writes, and removal so concurrent operations cannot diverge cache tiers.

- Resolve overlapping TLS pinning policies deterministically using the nearest matching ancestor.
- Normalize repeated leading endpoint slashes to match the documented URL construction contract.
- Share HTTP request assembly between standalone endpoints and the network client.
- Make the empty-response convenience available to all `APIClient` implementations.
- Replace stale architecture documentation and add GraphQL integration and review guidance.

Migration: endpoints relying on repeated leading slashes now produce a single
separator. Overlapping pinning policies now consistently select the most specific
matching policy; check pin sets before rollout. No deployment target change.
