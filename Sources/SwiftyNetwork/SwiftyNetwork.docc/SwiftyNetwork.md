# ``SwiftyNetwork``

A Swift networking library built for Swift 6 strict concurrency.

## Overview

SwiftyNetwork provides:

- **Type-safe endpoints** via the ``NetworkEndpoint`` protocol.
- **Actor-based requests** with ``NetworkClient``, including auth refresh on `401`.
- **Composable caching** with ``InMemoryCache`` and ``LayeredCache``.
- **Repository coordination** with ``GenericRepository`` and ``CachePolicy``.
- **Pluggable authentication** via ``AuthorizationProvider`` and ``OAuthAuthorizationProvider``.
- **Optional SSL pinning** via ``SSLPinningConfiguration`` for controlled hosts.
- **Safe redirects** via ``RedirectPolicy``: credentials are stripped from cross-origin redirects, and HTTPS downgrades are refused.
- **Opt-in request retries** with ``NetworkRetryPolicy``: idempotent requests retry on `429` and 5xx (honoring `Retry-After` on `429` and `503`), timeouts and lost connectivity, with jittered, capped backoff.
- **Fire-and-forget mutations** with ``MutationQueue``, including background retry, coalescing, and pluggable persistence via ``MutationStore``.
- **Single-flight remote data caching** with ``RemoteDataCache`` -- deduplicates concurrent fetches for the same key, composable with any ``Cache`` for app-configurable memory/disk layering.
- **Pluggable instrumentation** via ``NetworkInstrumentation`` for OpenTelemetry-style request tracing, with shared ``NetworkError/classification`` for retry policies and telemetry alike.

For tests and previews, the separate `SwiftyNetworkTesting` library product provides
`MockAPIClient`, a scriptable ``APIClient`` that records every request, and
`TestAuthorizationProvider`, a scriptable ``AuthorizationProvider`` that counts refreshes. Link it
from test targets only, never from production targets.

For streaming or other transports ``NetworkClient`` cannot model, use
``NetworkClient/sendAuthorized(_:errorBody:transport:)`` to keep its authorization, `401` refresh-once,
and redirect handling.

### Versioning

SwiftyNetwork follows Semantic Versioning. Its public enums, such as ``NetworkError``,
``MutationStatus``, and ``MutationFailureReason/Category``, gain new cases only in a major
release, so an exhaustive `switch` over them keeps compiling across minor and patch releases.
Types meant to grow, such as ``HTTPMethod`` and ``RedirectPolicy``, are structs.

## Topics

### Upgrading

- <doc:MigratingTo2>

### Essentials

- ``NetworkEndpoint``
- ``HTTPMethod``
- ``NetworkClient``
- ``NetworkClientConfiguration``
- ``NetworkRetryPolicy``
- ``BackoffPolicy``
- ``APIClient``
- ``DecodedResponse``
- ``EmptyResponse``
- ``NetworkError``
- ``NetworkErrorClassification``
- ``NetworkErrorCategory``
- ``HTTPResponse``

### Instrumentation

- ``NetworkInstrumentation``
- ``NetworkRequestAttempt``
- ``NetworkRequestCompletion``
- ``NetworkRequestFailure``

### Authentication

- ``AuthorizationType``
- ``AuthorizationProvider``
- ``OAuthAuthorizationProvider``

### Security

- ``SSLPinningConfiguration``
- ``RedirectPolicy``

### Caching

- ``Cache``
- ``CacheEntry``
- ``InMemoryCache``
- ``LayeredCache``
- ``CacheKey``
- ``CachePolicy``
- ``SingleFlightCache``
- ``RemoteDataCache``

### Repository

- ``Repository``
- ``GenericRepository``

### Mutations

- ``MutationQueue``
- ``MutationRequest``
- ``MutationKey``
- ``MutationStatus``
- ``MutationFailureReason``
- ``MutationRetryPolicy``
- ``MutationStore``
- ``InMemoryMutationStore``

### Guides

- <doc:CustomDiskCache>

### Reachability

- ``NetworkMonitor``
- ``NetworkReachability``

### Logging

- ``LogLevel``

### Tutorials

- <doc:GettingStarted>
- <doc:Caching>
- <doc:Authentication>
