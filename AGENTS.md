# SwiftyNetwork - Agent Guidelines

> Quick reference for AI agents working on this codebase

## Overview

SwiftyNetwork provides modern Swift networking with authentication, caching, and retry logic. Built for Swift 6.2+ with actors, async/await, and structured concurrency.

**Key Features:**
- Type-safe endpoints via `NetworkEndpoint` protocol
- Actor-based `NetworkClient` with retry and auth refresh
- Flexible caching (in-memory, layered, custom persistent)
- Repository pattern for network + local data coordination

## Project Structure

```
Sources/SwiftyNetwork/
├── Network/      # Client, endpoints, errors, authorization
├── Cache/        # Protocols + implementations (InMemory, Layered)
├── Repository/   # GenericRepository, data sources
└── Logger.swift  # Logging helper (uses SwiftUtils)

Tests/SwiftyNetworkTests/
├── Network/      # Client, endpoint, error tests
├── Cache/        # Cache implementation tests
├── Repository/   # Repository pattern tests
└── Helpers/      # TestURLProtocol, test utilities
```

## Quick Commands

```bash
# Build
swift build                  # Debug
swift build -c release       # Release

# Test
swift test                   # All tests
swift test --filter CacheTests  # Specific suite

# Documentation
swift package generate-documentation \
  --target SwiftyNetwork \
  --transform-for-static-hosting \
  --output-path docs
```

## Code Style

**Concurrency:**
- ✅ Use `async/await`, `actor`, `@Sendable`
- ✅ Structured concurrency (`async let`, `TaskGroup`)
- ❌ Avoid GCD, completion handlers

**Naming:**
- Types/Protocols/Actors: `PascalCase` (`NetworkClient`, `CachePolicy`)
- Functions/Properties: `lowerCamelCase`
- Tests: Match type name + `Tests` (`NetworkClientTests`)

**Organization:**
- One primary type per file
- Group extensions by responsibility
- Use DocC comments (`///`) for public APIs
- 4-space indentation

## Testing

**Framework:** Swift Testing (`@Test`, `#expect`)

**Requirements:**
- ✅ Test success AND failure paths
- ✅ Cover cache expiration, auth refresh, error cases
- ✅ Use mocks from `Tests/Helpers/` (e.g., `TestURLProtocol`, `MockNetworkDataSource`)
- ✅ Ensure tests pass locally before pushing
- ✅ Use `Issue.record()` for expected error paths (not `#expect(false)`)

**Test Utilities:**
- `TestURLProtocol.Response.success(data)` - 200 OK responses
- `TestURLProtocol.Response.status(code)` - Specific status codes
- `TestURLProtocol.Response.failure(error)` - Error responses
- `makeTestSession()` - Ephemeral session with TestURLProtocol

## Git Workflow

**Commits:**
- Use imperative mood: `"Add cache size limits"` not `"Added..."`
- Optional scope prefix: `cache:`, `network:`, `docs:`
- Include `Fixes #123` for issue references
- End with co-author tag:
  ```
  Co-Authored-By: Claude Sonnet 4.5 <noreply@anthropic.com>
  ```

**Pull Requests:**
- Summary of changes and architectural impact
- Testing evidence (command outputs, test results)
- Migration notes if breaking changes
- Update CHANGELOG.md

## Architecture Patterns

**NetworkClient:**
- Primary API surface for consumers
- Endpoints conform to `NetworkEndpoint` protocol
- Authorization via `AuthorizationType` or `AuthorizationProvider`
- Automatic retry on 401 with auth refresh

**Caching:**
- Memory-first: `InMemoryCache` with optional LRU eviction (maxSize)
- Layered: `LayeredCache(memoryCache, persistentCache)` for disk backing
- Type-erased: `AnyCache` for protocol flexibility
- Custom persistent caches: implement `PersistentCache` protocol

**Repository Pattern:**
- `GenericRepository` coordinates network + local data sources
- Cache policies: `returnCacheElseLoad`, `reloadIgnoringCache`, `returnCacheIfNotExpired(maxAge:)`
- Read from cache first, fall back to network, write back to cache

**Logging:**
- Use `Logger.debug()`, `.info()`, `.warning()`, `.error()`
- Package name constant: `swiftyNetworkPackageName`
- Never log tokens, credentials, or PII

## Security

**Never commit:**
- ❌ API keys, tokens, credentials
- ❌ Production URLs or endpoints
- ❌ Secrets in test files

**Best practices:**
- ✅ Inject auth via `AuthorizationProvider`
- ✅ Use dependency injection for configuration
- ✅ Scrub sensitive headers before logging
- ✅ Validate URLs (scheme, host) in endpoints
- ✅ Document required environment variables

## Key Files

- **PLAN.md** - Implementation planning guide and checklists
- **AGENTS.md** - This file (quick reference for agents)
- **README.md** - User-facing documentation with examples
- **CHANGELOG.md** - Version history and breaking changes

## Additional Resources

- [Swift Evolution](https://apple.github.io/swift-evolution/) - Language proposals
- [Swift.org](https://swift.org) - Official Swift documentation
- See PLAN.md for detailed implementation guidance
