# ``SwiftyNetwork``

A zero-dependency Swift networking library built for Swift 6 strict concurrency.

## Overview

SwiftyNetwork provides:

- **Type-safe endpoints** via the ``NetworkEndpoint`` protocol.
- **Actor-based requests** with ``NetworkClient``, including auth refresh on `401`.
- **Composable caching** with ``InMemoryCache`` and ``LayeredCache``.
- **Repository coordination** with ``GenericRepository`` and ``CachePolicy``.
- **Pluggable authentication** via ``AuthorizationProvider`` and ``OAuthAuthorizationProvider``.
- **Optional SSL pinning** via ``SSLPinningConfiguration`` for controlled hosts.
- **Fire-and-forget mutations** with ``MutationQueue``, including background retry, coalescing, and pluggable persistence via ``MutationStore``.
- **Single-flight remote data caching** with ``RemoteDataCache`` -- deduplicates concurrent fetches for the same key, composable with any ``Cache`` for app-configurable memory/disk layering.
- **Pluggable instrumentation** via ``NetworkInstrumentation`` for OpenTelemetry-style request tracing, with shared ``NetworkError/classification`` for retry policies and telemetry alike.

## Topics

### Essentials

- ``NetworkEndpoint``
- ``HTTPMethod``
- ``NetworkClient``
- ``NetworkClientConfiguration``
- ``APIClient``
- ``NetworkDataSource``
- ``EmptyResponse``
- ``NetworkError``
- ``NetworkErrorClassification``

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

### Caching

- ``Cache``
- ``TimestampedCache``
- ``PersistentCache``
- ``InMemoryCache``
- ``LayeredCache``
- ``AnyCache``
- ``CacheKey``
- ``CachePolicy``
- ``SingleFlightCache``
- ``RemoteDataCache``

### Repository

- ``Repository``
- ``GenericRepository``
- ``LocalDataSource``
- ``CacheBasedLocalDataSource``

### Mutations

- ``MutationQueue``
- ``MutationRequest``
- ``MutationKey``
- ``MutationStatus``
- ``MutationFailureReason``
- ``MutationRetryPolicy``
- ``MutationStore``
- ``InMemoryMutationStore``

### Reachability

- ``NetworkMonitor``
- ``NetworkReachability``

### Logging

- ``LogLevel``

### Tutorials

- <doc:GettingStarted>
- <doc:Caching>
- <doc:Authentication>
