# ``SwiftyNetwork``

A zero-dependency Swift networking library built for Swift 6 strict concurrency.

## Overview

SwiftyNetwork provides:

- **Type-safe endpoints** via the ``NetworkEndpoint`` protocol.
- **Actor-based requests** with ``NetworkClient``, including auth refresh on `401`.
- **Composable caching** with ``InMemoryCache`` and ``LayeredCache``.
- **Repository coordination** with ``GenericRepository`` and ``CachePolicy``.
- **Pluggable authentication** via ``AuthorizationProvider`` and ``OAuthAuthorizationProvider``.

## Topics

### Essentials

- ``NetworkEndpoint``
- ``HTTPMethod``
- ``NetworkClient``
- ``NetworkClientConfiguration``
- ``NetworkError``

### Authentication

- ``AuthorizationType``
- ``AuthorizationProvider``
- ``OAuthAuthorizationProvider``

### Caching

- ``Cache``
- ``TimestampedCache``
- ``PersistentCache``
- ``InMemoryCache``
- ``LayeredCache``
- ``AnyCache``
- ``CacheKey``
- ``CachePolicy``

### Repository

- ``Repository``
- ``GenericRepository``
- ``LocalDataSource``
- ``CacheBasedLocalDataSource``

### Reachability

- ``NetworkMonitor``
- ``NetworkReachability``

### Logging

- ``LogLevel``

### Tutorials

- <doc:GettingStarted>
- <doc:Caching>
- <doc:Authentication>
