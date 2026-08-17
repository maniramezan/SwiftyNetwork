# SwiftyNetwork

[![Build](https://img.shields.io/github/actions/workflow/status/maniramezan/SwiftyNetwork/build.yml?branch=main&label=build)](https://github.com/maniramezan/SwiftyNetwork/actions/workflows/build.yml)
[![Swift Versions](https://img.shields.io/endpoint?url=https://swiftpackageindex.com/api/packages/maniramezan/SwiftyNetwork/badge?type=swift-versions)](https://swiftpackageindex.com/maniramezan/SwiftyNetwork)
[![Platforms](https://img.shields.io/endpoint?url=https://swiftpackageindex.com/api/packages/maniramezan/SwiftyNetwork/badge?type=platforms)](https://swiftpackageindex.com/maniramezan/SwiftyNetwork)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

A modern, Swift-native networking library built with Swift 6 concurrency, providing a clean and type-safe API for network operations with built-in caching, authentication, and error handling.

## Features

- **Swift 6 Concurrency**: Built with async/await and actors for thread-safe operations
- **Type-Safe Endpoints**: Protocol-based endpoint definitions with compile-time safety
- **Flexible Caching**: Pluggable caching system with multiple policies
- **Authentication Support**: Built-in OAuth and custom authentication providers
- **SSL Pinning**: Optional certificate and public-key pinning for controlled hosts
- **Comprehensive Error Handling**: Detailed error types with localized descriptions
- **Repository Pattern**: Clean separation between network and local data sources
- **Automatic Auth Refresh**: Refreshes credentials and replays the request once on `401`
- **Fire-and-Forget Mutations**: Background retry, key-based coalescing, and pluggable persistence via `MutationQueue`
- **Thread-Safe**: All operations are thread-safe using Swift's actor model

## Requirements

- Swift 6.0+
- iOS 17.0+ / macOS 14.0+

## Code Quality

This project uses [swift-format](https://github.com/swiftlang/swift-format) (Apple's official Swift formatter) for code formatting and linting.

### Local Development

Format code manually:

```bash
swift format format --in-place --recursive --parallel Sources Tests  # Format in-place
swift format lint --recursive --parallel Sources Tests                # Check for violations
```

Using SPM command plugins:

```bash
swift package plugin --allow-writing-to-package-directory swift-format
swift package plugin swift-format-lint
```

### CI

swift-format runs in strict mode on all PRs (warnings treated as errors).
Configuration: `.swift-format`

## Installation

### Swift Package Manager

Add SwiftyNetwork to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/maniramezan/SwiftyNetwork.git", from: "0.1.0")
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
        maxAuthRefreshAttempts: 3,
        timeoutInterval: 30
    )
    let networkClient = NetworkClient(configuration: configuration)
    
    // Create cache-based local data source
    let cache = InMemoryCache<User>()
    let localDataSource = CacheBasedLocalDataSource(cache: cache)
    
    // Create and return repository
    return GenericRepository(
        networkDataSource: networkClient,
        localDataSource: localDataSource
    )
}
```

### Unified APIClient Interface

`NetworkClient` conforms to `APIClient`, so you can accept any implementation in higher-level code:

```swift
func fetchUser(client: APIClient, baseURL: String, userId: String) async throws -> User {
    let endpoint = UserEndpoint(baseURL: baseURL, userId: userId)
    return try await client.request(endpoint, responseType: User.self)
}
```

### Layered Caching with a Custom Persistent Cache

Implement `PersistentCache` in your app to define on-disk behavior, then combine it with
the built-in in-memory cache using `LayeredCache`.

```swift
public actor UserDiskCache: PersistentCache {
    public typealias Value = User
    // Replace this storage with file-backed I/O in your app.
    private var storage: [CacheKey: (User, Date)] = [:]

    public init() {}

    public func value(forKey key: CacheKey) async -> User? {
        storage[key]?.0
    }

    public func setValue(_ value: User, forKey key: CacheKey) async {
        storage[key] = (value, Date())
    }

    public func removeValue(forKey key: CacheKey) async {
        storage.removeValue(forKey: key)
    }

    public func removeAll() async {
        storage.removeAll()
    }

    public func timestamp(forKey key: CacheKey) async -> Date? {
        storage[key]?.1
    }
}

func createLayeredRepository() -> GenericRepository<User> {
    let memoryCache = InMemoryCache<User>()
    let diskCache = UserDiskCache()
    let layeredCache = LayeredCache(memoryCache: memoryCache, persistentCache: diskCache)
    let localDataSource = CacheBasedLocalDataSource(cache: layeredCache)

    return GenericRepository(
        networkDataSource: NetworkClient.shared,
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
        maxAuthRefreshAttempts: 2
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

### Fire-and-Forget Mutations with MutationQueue

Use `MutationQueue` for "forgivable" mutations -- liking a post, updating a setting -- that
shouldn't block the UI on the network round trip and shouldn't be silently lost to a transient
failure. `NetworkClient` deliberately doesn't retry transient/5xx errors on its own; `MutationQueue`
is the dedicated retry loop for this class of call, with exponential backoff, coalescing by key,
and status reporting.

```swift
let queue = MutationQueue(client: NetworkClient.shared)

// Enqueue returns immediately; the network call and any retries run in the background.
let request = MutationRequest(endpoint: LikeVideoEndpoint(videoID: "42"))
await queue.enqueue(request, key: "like:video:42")

// Rapid toggling coalesces to the latest desired state instead of replaying
// every intermediate call.
let undo = MutationRequest(endpoint: UnlikeVideoEndpoint(videoID: "42"))
await queue.enqueue(undo, key: "like:video:42")

// Observe outcomes to reflect status in the UI; MutationQueue reports what
// happened, it doesn't manage optimistic UI state itself.
for await event in await queue.events() where event.key == "like:video:42" {
    switch event.status {
    case .succeeded:
        break
    case .failed:
        showLikeFailedError()
    case .pending, .retrying:
        break
    }
}
```

Persistence is pluggable via the `MutationStore` protocol. `InMemoryMutationStore` ships as the
default (mutations are lost if the process is killed, which is fine for most forgivable
mutations); implement `MutationStore` yourself for durable persistence that survives a relaunch.
Because `MutationRequest` is `Codable`, a durable store can serialize "which endpoint plus what
body" directly and replay it on the next launch via `resumePendingMutations()`.

```swift
let queue = MutationQueue(client: NetworkClient.shared, store: MyDurableMutationStore())
await queue.resumePendingMutations() // call once at startup
```

> **Note:** `MutationRequest` can carry secrets (bearer tokens, API keys) via its captured
> `AuthorizationType`. A durable `MutationStore` is responsible for storing the encoded request
> securely (e.g. Keychain-backed) -- SwiftyNetwork does not encrypt persisted mutations itself.

### SSL Pinning

Use SSL pinning when your app and API are operated together and you can safely rotate pins before server
certificates or keys change. Pinning is enforced only for configured hosts; all other hosts use normal
`URLSession` trust handling.

```swift
func makePinnedClient() throws -> NetworkClient {
    guard let apiPublicKeyPin = SSLPinningConfiguration.Pin.publicKeySHA256(
        base64Encoded: "BASE64_ENCODED_SHA256_PUBLIC_KEY_HASH"
    ) else {
        throw NetworkError.invalidData
    }

    let pinning = SSLPinningConfiguration(
        pinnedHosts: [
            "api.example.com": [apiPublicKeyPin]
        ],
        includesSubdomains: false,
        requiresDefaultTrustValidation: true
    )

    let configuration = NetworkClientConfiguration(
        sslPinning: pinning,
        timeoutInterval: 30
    )
    return NetworkClient(configuration: configuration)
}
```

Public-key pins use the industry-standard SPKI SHA-256 format (the same format as HPKP and TrustKit).
Generate one for a live server with:

```bash
openssl s_client -connect api.example.com:443 < /dev/null 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary \
  | base64
```

For certificate pins, use `.certificate(_:)` with DER certificate data or `.certificateSHA256(base64Encoded:)`.
For safer rotations, configure more than one accepted pin during certificate or key rollovers.

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
let local = CacheBasedLocalDataSource(cache: customCache)
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
    maxAuthRefreshAttempts: 3,
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
- **`SSLPinningConfiguration`**: Configures certificate and public-key pinning
- **`MutationQueue`**: Fire-and-forget mutations with background retry and coalescing
- **`MutationStore`**: Pluggable persistence for pending mutations

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
struct MockNetworkDataSource<R: Decodable & Sendable>: NetworkDataSource {
    let mockResponse: R

    func request<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        responseType: T.Type
    ) async throws -> T {
        guard let typed = mockResponse as? T else {
            throw NetworkError.invalidResponse
        }
        return typed
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

We welcome contributions! Please read our [CONTRIBUTING.md](CONTRIBUTING.md) guidelines and submit pull requests to our GitHub repository.

### Running Tests

```bash
# Run all tests
swift test

# Run tests with coverage
swift test --enable-code-coverage

# Generate coverage report
xcrun llvm-cov report .build/debug/SwiftyNetworkPackageTests.xctest/Contents/MacOS/SwiftyNetworkPackageTests \
  -instr-profile .build/debug/codecov/default.profdata
```

The test suite covers caching, networking, auth, SSL pinning, and repository flows.

## License

SwiftyNetwork is available under the MIT license. See the [LICENSE](LICENSE) file for more info.

## Support

- **Documentation**: Full API documentation is published via GitHub Pages
- **Live docs**: [https://maniramezan.github.io/SwiftyNetwork](https://maniramezan.github.io/SwiftyNetwork)
- **Issues**: [GitHub Issues](https://github.com/maniramezan/SwiftyNetwork/issues)
- **Discussions**: [GitHub Discussions](https://github.com/maniramezan/SwiftyNetwork/discussions)
