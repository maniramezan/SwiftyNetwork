# SwiftyNetwork

A modern, Swift-native networking library built with Swift 6 concurrency, providing a clean and type-safe API for network operations with built-in caching, authentication, and error handling.

## Features

- **Swift 6 Concurrency**: Built with async/await and actors for thread-safe operations
- **Type-Safe Endpoints**: Protocol-based endpoint definitions with compile-time safety
- **Flexible Caching**: Pluggable caching system with multiple policies
- **Authentication Support**: Built-in OAuth and custom authentication providers
- **Comprehensive Error Handling**: Detailed error types with localized descriptions
- **Repository Pattern**: Clean separation between network and local data sources
- **Automatic Retry**: Configurable retry logic with exponential backoff
- **Thread-Safe**: All operations are thread-safe using Swift's actor model

## Requirements

- Swift 6.0+
- iOS 15.0+ / macOS 15.0+

## Installation

### Swift Package Manager

Add SwiftyNetwork to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/yourorg/SwiftyNetwork.git", from: "1.0.0")
]
```

Or add it through Xcode: File → Add Package Dependencies → Enter the repository URL.

## Quick Start

### 1. Define an Endpoint

```swift
/// Example endpoint implementation for a REST API.
public struct UserEndpoint: NetworkEndpoint {
    public let baseURL: String
    public let userId: String
    
    public init(baseURL: String, userId: String) {
        self.baseURL = baseURL
        self.userId = userId
    }
    
    public var path: String {
        "/users/\(userId)"
    }
    
    public var method: HTTPMethod {
        .get
    }
    
    public var headers: [String : String]? {
        ["Accept": "application/json"]
    }
}
```

### 2. Create a Data Model

```swift
/// Example user model.
public struct User: Codable, Sendable {
    public let id: String
    public let name: String
    public let email: String
    
    public init(id: String, name: String, email: String) {
        self.id = id
        self.name = name
        self.email = email
    }
}
```

### 3. Make a Network Request

```swift
// Simple network request
let client = NetworkClient.shared
let endpoint = UserEndpoint(baseURL: "https://api.example.com", userId: "123")

do {
    let user = try await client.request(endpoint, responseType: User.self)
    print("User: \(user.name)")
} catch {
    print("Error: \(error)")
}
```

## Advanced Usage

### Complete Repository Setup with Caching

```swift
/// Example function showing how to set up a complete repository with caching.
func createUserRepository() -> GenericRepository<User> {
    // Create network client with configuration
    let configuration = NetworkClientConfiguration(
        maxRetryAttempts: 3,
        timeoutInterval: 30
    )
    let networkClient = NetworkClient(configuration: configuration)
    
    // Create cache-based local data source
    let cache = InMemoryCache<User>()
    let anyCache = AnyCache(cache)
    let localDataSource = CacheBasedLocalDataSource(cache: anyCache)
    
    // Create and return repository
    return GenericRepository(
        networkDataSource: networkClient,
        localDataSource: localDataSource
    )
}
```

### Fetching with Different Cache Strategies

```swift
// Example 1: Cache-first strategy
func fetchUser(userId: String, baseURL: String) async throws -> User {
    let repository = createUserRepository()
    let endpoint = UserEndpoint(baseURL: baseURL, userId: userId)
    let cacheKey = CacheKey.user(userId, resource: "profile")
    
    // Fetch with cache fallback - tries cache first, then network
    return try await repository.fetch(
        using: endpoint,
        cacheKey: cacheKey,
        policy: .returnCacheElseLoad
    )
}

// Example 2: Force refresh from network
func refreshUser(userId: String, baseURL: String) async throws -> User {
    let repository = createUserRepository()
    let endpoint = UserEndpoint(baseURL: baseURL, userId: userId)
    let cacheKey = CacheKey.user(userId, resource: "profile")
    
    // Always fetch from network and update cache
    return try await repository.fetch(
        using: endpoint,
        cacheKey: cacheKey,
        policy: .reloadIgnoringCache
    )
}

// Example 3: Cache with expiration
func fetchUserWithExpiration(
    userId: String, 
    baseURL: String,
    maxCacheAge: TimeInterval = 300 // 5 minutes
) async throws -> User {
    let repository = createUserRepository()
    let endpoint = UserEndpoint(baseURL: baseURL, userId: userId)
    let cacheKey = CacheKey.user(userId, resource: "profile")
    
    // Use cached data if not older than maxCacheAge, otherwise fetch from network
    return try await repository.fetch(
        using: endpoint,
        cacheKey: cacheKey,
        policy: .returnCacheIfNotExpired(maxAge: maxCacheAge)
    )
}
```

### OAuth Authentication

```swift
/// Example showing OAuth authentication setup.
func createAuthenticatedClient(accessToken: String) -> NetworkClient {
    let authProvider = OAuthAuthorizationProvider(initialAccessToken: accessToken) {
        // In a real app, this would refresh the token using a refresh token
        // For this example, we just return nil to indicate refresh failure
        return nil
    }
    
    let configuration = NetworkClientConfiguration(
        authorizationProvider: authProvider,
        maxRetryAttempts: 2
    )
    
    return NetworkClient(configuration: configuration)
}

// Usage
let authenticatedClient = createAuthenticatedClient(accessToken: "your-access-token")
let endpoint = UserEndpoint(baseURL: "https://api.example.com", userId: "123")

do {
    let user = try await authenticatedClient.request(endpoint, responseType: User.self)
    print("Authenticated request successful: \(user.name)")
} catch {
    print("Error: \(error)")
}
```

### Custom Cache Implementation

```swift
// Implement custom cache
public actor MyCustomCache<T: Sendable>: Cache {
    public typealias Value = T
    
    // Your custom cache implementation here
    public func value(forKey key: CacheKey) async -> T? { /* ... */ }
    public func setValue(_ value: T, forKey key: CacheKey) async { /* ... */ }
    public func removeValue(forKey key: CacheKey) async { /* ... */ }
    public func removeAll() async { /* ... */ }
    public func timestamp(forKey key: CacheKey) async -> Date? { /* ... */ }
}

// Use with repository
let customCache = MyCustomCache<User>()
let anyCache = AnyCache(customCache)
// ... rest of repository setup
```

## Cache Policies

SwiftyNetwork supports three caching strategies:

- **`.returnCacheElseLoad`**: Return cached data if available, otherwise fetch from network
- **`.reloadIgnoringCache`**: Always fetch from network and update cache
- **`.returnCacheIfNotExpired(maxAge:)`**: Use cached data if not older than specified age

## Error Handling

SwiftyNetwork provides comprehensive error handling:

```swift
do {
    let user = try await client.request(endpoint, responseType: User.self)
} catch NetworkError.unauthorized {
    // Handle authentication error
} catch NetworkError.serverError(let statusCode, let data) {
    // Handle server error with specific status code
} catch NetworkError.decodingFailed(let underlying) {
    // Handle JSON decoding error
} catch {
    // Handle other errors
}
```

## Configuration

### Network Client Configuration

```swift
let configuration = NetworkClientConfiguration(
    session: URLSession.shared,
    decoder: JSONDecoder(),
    encoder: JSONEncoder(),
    authorizationProvider: authProvider,
    maxRetryAttempts: 3,
    timeoutInterval: 30
)

let client = NetworkClient(configuration: configuration)
```

### Custom JSON Decoding

```swift
let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
decoder.keyDecodingStrategy = .convertFromSnakeCase

let configuration = NetworkClientConfiguration(decoder: decoder)
```

## Architecture

SwiftyNetwork is built around several key protocols and types:

- **`NetworkEndpoint`**: Defines API endpoints
- **`NetworkDataSource`**: Abstract network request interface
- **`Cache`**: Generic caching interface
- **`LocalDataSource`**: Local storage abstraction
- **`Repository`**: Combines network and local data sources
- **`AuthorizationProvider`**: Handles authentication

This design promotes clean separation of concerns, testability, and flexibility.

## Thread Safety

All operations in SwiftyNetwork are thread-safe:

- Network clients use Swift actors for thread-safe state management
- Caches are implemented as actors
- All protocols are marked as `Sendable`

## Testing

SwiftyNetwork's protocol-based design makes it easy to test:

```swift
// Mock network data source
struct MockNetworkDataSource: NetworkDataSource {
    let mockResponse: Any
    
    func request<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint, 
        responseType: T.Type
    ) async throws -> T {
        return mockResponse as! T
    }
}

// Use in tests
let mockDataSource = MockNetworkDataSource(mockResponse: mockUser)
let repository = GenericRepository(
    networkDataSource: mockDataSource,
    localDataSource: mockLocalDataSource
)
```

## Contributing

We welcome contributions! Please read our contributing guidelines and submit pull requests to our GitHub repository.

## License

SwiftyNetwork is available under the MIT license. See the LICENSE file for more info.

## Support

- Documentation: Full API documentation is published via GitHub Pages (CI updates the site on pushes to main).

- Live docs: [https://yourorg.github.io/SwiftyNetwork](https://yourorg.github.io/SwiftyNetwork)

- To regenerate docs locally (requires a recent Xcode / Swift toolchain with DocC support):

    1. Open the package in Xcode and use Product → Build Documentation, or
    2. Use the Swift package command on a supporting toolchain:

    ```bash
    swift package generate-documentation --target SwiftyNetwork --transform-for-static-hosting --output-path docs
    ```

    The generated static site will be emitted into the `docs/` directory and the repository's GitHub Actions workflow will publish it to the `gh-pages` branch.

- Issues: [GitHub Issues](https://github.com/yourorg/SwiftyNetwork/issues)
- Discussions: [GitHub Discussions](https://github.com/yourorg/SwiftyNetwork/discussions)
