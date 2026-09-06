# SwiftyNetwork Implementation Planning Guide

This document provides guidance for planning and implementing features in SwiftyNetwork.

## Planning Checklist

When planning a new feature or significant change, consider:

### 1. Architecture & Design
- [ ] Does this fit within the existing NetworkClient/Cache/Repository architecture?
- [ ] Will it require new protocols or can it extend existing ones?
- [ ] Are there backward compatibility concerns?
- [ ] Should this be actor-isolated for thread safety?

### 2. API Surface
- [ ] Is the public API intuitive and consistent with Swift conventions?
- [ ] Does it follow the existing naming patterns in the codebase?
- [ ] Can it be misused? Add safeguards if so.
- [ ] Does it need configuration options?

### 3. Testing Strategy
- [ ] What are the success paths to test?
- [ ] What failure modes need coverage?
- [ ] Are there edge cases (empty data, network errors, auth failures)?
- [ ] Do we need mock implementations?

### 4. Performance
- [ ] Will this introduce latency?
- [ ] Does it need caching?
- [ ] Are there memory implications (cache size, retention)?
- [ ] Could it benefit from async/await optimizations?

### 5. Security
- [ ] Does it handle sensitive data (tokens, credentials)?
- [ ] Are there injection risks (URL, SQL, etc.)?
- [ ] Should errors leak implementation details?
- [ ] Does logging expose secrets?

### 6. Documentation
- [ ] Public APIs need DocC comments
- [ ] README examples for common use cases
- [ ] Migration guide if breaking changes
- [ ] Update AGENTS.md if workflow changes

## Common Implementation Patterns

### Adding a New Cache Type

1. Conform to `Cache` protocol (or `TimestampedCache` for timestamp preservation)
2. Implement as `actor` for thread safety
3. Add comprehensive tests (store, retrieve, remove, timestamps)
4. Document example usage in README
5. Consider adding to `LayeredCache` if it's a persistent cache

### Adding Network Features

1. Extend `NetworkEndpoint` protocol or add to `NetworkClient`
2. Update `NetworkError` if new error cases needed
3. Add logging via `Logger` helper
4. Test with `TestURLProtocol` mock
5. Document authorization requirements

### Repository Pattern Changes

1. Consider impact on `GenericRepository`
2. Test all cache policies (returnCacheElseLoad, reloadIgnoringCache, returnCacheIfNotExpired)
3. Ensure network/local data sources are properly coordinated
4. Add integration tests with real `NetworkClient` + `InMemoryCache`

## File Organization

```
Sources/SwiftyNetwork/
├── Network/          # HTTP client, endpoints, errors
├── Cache/            # Cache protocols and implementations
└── Repository/       # Data coordination layer

Tests/SwiftyNetworkTests/
├── Network/          # Network client tests
├── Cache/            # Cache implementation tests
├── Repository/       # Repository pattern tests
└── Helpers/          # Test utilities and mocks
```

## Decision Framework

### When to Use Actors
- Any mutable state shared across concurrency contexts
- Network clients, caches, data stores
- Not needed for pure value types or immutable data

### When to Add Configuration
- Feature has multiple reasonable defaults
- Behavior varies per use case (timeouts, retry counts)
- Security-sensitive settings (max cache size, URL validation)

### When to Break Backward Compatibility
- Only for major versions
- Provide deprecation warnings first
- Document migration paths in the pull request description
- Consider adding compatibility shims

## Anti-Patterns to Avoid

### Don't
- ❌ Force unwrap (`!`) - use proper error handling
- ❌ Use `class` when `actor` provides safety
- ❌ Hardcode URLs, timeouts, or credentials
- ❌ Log sensitive data (tokens, PII)
- ❌ Create abstractions for single-use cases
- ❌ Add features without tests
- ❌ Use completion handlers (use async/await)

### Do
- ✅ Leverage Swift 6 concurrency (async/await, actors)
- ✅ Use value types when possible
- ✅ Provide sensible defaults with opt-in configuration
- ✅ Write tests before implementation (TDD-style)
- ✅ Use `#Preview` for SwiftUI components (if applicable)
- ✅ Document with DocC-style comments

## Release Checklist

Before releasing a new version:

1. [ ] All tests pass (`swift test`)
2. [ ] Documentation is updated (README, DocC)
3. [ ] Pull request describes user-facing changes and migration notes
4. [ ] No compiler warnings
5. [ ] Backward compatibility preserved (or documented)
6. [ ] Version number bumped in appropriate places
7. [ ] Code reviewed by another contributor
8. [ ] Performance benchmarks pass (if applicable)

## Getting Help

- Check existing code for similar patterns
- Review Swift Evolution proposals for new language features
- Consult AGENTS.md for repository conventions
- Open a discussion issue for architectural questions
