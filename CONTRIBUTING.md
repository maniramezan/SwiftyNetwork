# Contributing to SwiftyNetwork

Thank you for your interest in contributing to SwiftyNetwork! We welcome contributions from the community.

## Getting Started

1. **Fork the repository** and clone your fork
2. **Create a branch** for your feature or bug fix
3. **Make your changes** following our code style guidelines
4. **Write tests** for your changes
5. **Ensure all tests pass** and code is formatted
6. **Submit a pull request** with a clear description

## Development Setup

### Requirements
- Swift 6.0+
- Xcode 16.0+ (for iOS/macOS development)
- macOS 14.0+ (package minimum; your Xcode version may require a newer macOS)

### Building the Project

```bash
swift build
```

### Running Tests

```bash
swift test
```

### Code Formatting

This project uses [swift-format](https://github.com/swiftlang/swift-format) for consistent code style.

**Format your code before committing:**

```bash
swift format format -i -r -p Sources Tests
```

**Check for violations:**

```bash
swift format lint -r -p Sources Tests
```

Configuration is defined in `.swift-format` at the repository root.

## Code Style Guidelines

### General Principles
- Write clear, readable code with self-documenting names
- Follow Swift API Design Guidelines
- Prefer composition over inheritance
- Keep functions small and focused

### Swift 6 Concurrency
- ✅ Use `async/await` for asynchronous operations
- ✅ Use `actor` for thread-safe state management
- ✅ Mark types as `Sendable` where appropriate
- ✅ Use structured concurrency (`async let`, `TaskGroup`)
- ❌ Avoid GCD and completion handlers

### Naming Conventions
- **Types/Protocols/Actors**: `PascalCase` (e.g., `NetworkClient`, `CachePolicy`)
- **Functions/Properties/Variables**: `lowerCamelCase` (e.g., `fetchUser`, `maxAuthRefreshAttempts`)
- **Test Methods**: Descriptive names using `@Test` attribute

### Documentation
- **All public APIs must have DocC comments** (`///`)
- Include parameter descriptions and return values
- Add code examples for complex APIs
- Use proper DocC formatting:

```swift
/// Brief description of the type or function.
///
/// Detailed explanation of behavior, use cases, or important notes.
///
/// Example:
/// ```swift
/// let client = NetworkClient.shared
/// let user = try await client.request(endpoint, responseType: User.self)
/// ```
///
/// - Parameters:
///   - endpoint: The endpoint to request.
///   - responseType: The expected response type.
/// - Returns: The decoded response object.
/// - Throws: `NetworkError` if the request fails.
public func request<T: Decodable>(...) async throws -> T
```

### File Organization
- One primary type per file
- Group related extensions together
- Use `// MARK: -` comments for logical sections
- 4-space indentation (enforced by swift-format)

## Testing Guidelines

We use **Swift Testing** framework (`@Test`, `#expect`).

### Test Requirements
- ✅ Test both success and failure paths
- ✅ Cover edge cases and error conditions
- ✅ Use mocks/stubs from `Tests/Helpers/`
- ✅ Ensure tests are deterministic and independent
- ✅ Use descriptive test names

### Test Structure Example

```swift
import Testing
@testable import SwiftyNetwork

@Suite("NetworkClient Tests")
struct NetworkClientTests {
    
    @Test("Successfully fetches and decodes user data")
    func fetchUserSuccess() async throws {
        // Given
        let mockData = """
        {"id": "123", "name": "John"}
        """.data(using: .utf8)!
        
        // When
        let user = // ... perform action
        
        // Then
        #expect(user.id == "123")
        #expect(user.name == "John")
    }
    
    @Test("Throws error on invalid response")
    func fetchUserInvalidResponse() async throws {
        // Given
        // ... setup invalid response
        
        // When/Then
        await #expect(throws: NetworkError.invalidResponse) {
            try await client.request(endpoint, responseType: User.self)
        }
    }
}
```

### Running Specific Tests

```bash
# Run all tests
swift test

# Run specific test suite
swift test --filter NetworkClientTests

# Run with code coverage
swift test --enable-code-coverage
```

## Commit Guidelines

### Commit Message Format

Use clear, imperative commit messages:

```
Add support for custom cache implementations

- Introduce PersistentCache protocol
- Add LayeredCache for memory + disk caching
- Update documentation with examples

Co-Authored-By: Your Name <your.email@example.com>
```

### Commit Message Rules
- Use imperative mood: "Add feature" not "Added feature"
- First line is a summary (50 chars or less)
- Optional scope prefix: `cache:`, `network:`, `docs:`, `tests:`
- Include `Fixes #123` to reference issues
- Add `Co-Authored-By:` for pair programming or AI assistance

### Examples

```
network: Add retry logic with exponential backoff
cache: Fix memory leak in InMemoryCache
docs: Update README with OAuth examples
tests: Add coverage for edge cases in CachePolicy
```

## Pull Request Process

1. **Update documentation** if you're changing public APIs
2. **Add tests** for new functionality
3. **Ensure CI passes** - all checks must be green:
   - ✅ swift-format lint (strict mode)
   - ✅ Build succeeds
   - ✅ All tests pass
   - ✅ Code coverage is maintained or improved
4. **Describe user-facing changes and migration notes** in your pull request; do not add a changelog file
5. **Provide clear PR description**:
   - What problem does this solve?
   - What approach did you take?
   - Any breaking changes?
   - Related issues?

### PR Title Format

```
[Category] Brief description

Examples:
[Feature] Add support for WebSocket connections
[Fix] Resolve race condition in cache eviction
[Docs] Improve examples in README
[Refactor] Simplify endpoint URL construction
[Tests] Add integration tests for OAuth flow
```

## Code Review

- Be respectful and constructive
- Explain your reasoning
- Accept feedback gracefully
- Focus on code, not people
- Suggest alternatives when raising concerns

## Questions?

- **Issues**: Open a GitHub issue for bugs or feature requests
- **Discussions**: Use GitHub Discussions for questions and ideas
- **Security**: Report security vulnerabilities privately (see SECURITY.md if available)

## License

By contributing to SwiftyNetwork, you agree that your contributions will be licensed under the MIT License.

---

Thank you for contributing to SwiftyNetwork! 🚀
