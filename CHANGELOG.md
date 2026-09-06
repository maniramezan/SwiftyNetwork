# Changelog

## Unreleased


- Resolve overlapping TLS pinning policies deterministically using the nearest matching ancestor.
- Normalize repeated leading endpoint slashes to match the documented URL construction contract.
- Share HTTP request assembly between standalone endpoints and the network client.
- Make the empty-response convenience available to all `APIClient` implementations.
- Replace stale architecture documentation and add GraphQL integration and review guidance.

Migration: endpoints relying on repeated leading slashes now produce a single
separator. Overlapping pinning policies now consistently select the most specific
matching policy; check pin sets before rollout. No deployment target change.
