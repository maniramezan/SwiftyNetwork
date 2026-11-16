# SwiftyNetwork

[![Build](https://img.shields.io/github/actions/workflow/status/maniramezan/SwiftyNetwork/build.yml?branch=main&label=build)](https://github.com/maniramezan/SwiftyNetwork/actions/workflows/build.yml)
[![Swift Versions](https://img.shields.io/endpoint?url=https://swiftpackageindex.com/api/packages/maniramezan/SwiftyNetwork/badge?type=swift-versions)](https://swiftpackageindex.com/maniramezan/SwiftyNetwork)
[![Platforms](https://img.shields.io/endpoint?url=https://swiftpackageindex.com/api/packages/maniramezan/SwiftyNetwork/badge?type=platforms)](https://swiftpackageindex.com/maniramezan/SwiftyNetwork)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

SwiftyNetwork is a Swift-native networking library built for Swift 6 strict concurrency. It provides type-safe
endpoints, an actor-based HTTP client, composable caching, authentication, and a repository pattern.

## Features

- **Type-safe requests:** Protocol-based endpoints, typed responses, JSON and form request bodies.
- **Concurrency-safe client:** Async/await networking, optional idempotent retries, and coalesced authorization refresh.
- **Composable caching:** In-memory and disk caches, layered storage, repository policies, and conditional requests.
- **Offline mutations:** Background retries, key-based coalescing, status streams, and optional persistence.
- **Connection controls:** Optional TLS pinning, credential-safe redirects, and caller-supplied transports for streams.
- **Observability and testing:** Request instrumentation, reachability updates, and test doubles behind the `Testing` SPI.

## Requirements

- Swift 6.2+
- iOS 18.0+ / macOS 15.0+

SwiftyNetwork depends on [SwiftCommons](https://github.com/maniramezan/SwiftCommons), imported internally and not
exposed in its public API.

## Installation

Add SwiftyNetwork to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/maniramezan/SwiftyNetwork.git", from: "2.0.0")
]
```

Or add it in Xcode with **File > Add Package Dependencies** and the repository URL.

## Quick Start

Define an endpoint and a response model:

```swift
struct UserEndpoint: NetworkEndpoint {
    let baseURL = "https://api.example.com"
    let userID: String

    var path: String { "/users/\(userID)" }
    let method: HTTPMethod = .get
}

struct User: Decodable, Sendable {
    let id: String
    let name: String
}
```

Send the request:

```swift
let user = try await NetworkClient.shared.request(
    UserEndpoint(userID: "123"),
    responseType: User.self
)
print(user.name)
```

`NetworkClient` also supports typed endpoints, custom authorization providers, retries, instrumentation, and
configuration for headers, timeouts, JSON coders, and redirects.

## Guides

The [API documentation](https://maniramezan.github.io/SwiftyNetwork/documentation/swiftynetwork) contains the full
symbol reference, tutorials, and focused guides:

- [Getting started](https://maniramezan.github.io/SwiftyNetwork/tutorials/swiftynetwork/gettingstarted)
- [Authentication](https://maniramezan.github.io/SwiftyNetwork/tutorials/swiftynetwork/authentication)
- [Caching and repositories](https://maniramezan.github.io/SwiftyNetwork/tutorials/swiftynetwork/caching)
- [Errors and retries](https://maniramezan.github.io/SwiftyNetwork/documentation/swiftynetwork/handlingerrorsandretries)
- [Offline mutations](https://maniramezan.github.io/SwiftyNetwork/documentation/swiftynetwork/offlinemutations)
- [Securing connections](https://maniramezan.github.io/SwiftyNetwork/documentation/swiftynetwork/securingconnections)
- [Streaming responses](https://maniramezan.github.io/SwiftyNetwork/documentation/swiftynetwork/streamingresponses)
- [Custom disk caches](https://maniramezan.github.io/SwiftyNetwork/documentation/swiftynetwork/customdiskcache)
- [Testing with SwiftyNetwork](https://maniramezan.github.io/SwiftyNetwork/documentation/swiftynetwork/testingwithswiftynetwork)
- [Migrating from 1.x to 2.x](https://maniramezan.github.io/SwiftyNetwork/documentation/swiftynetwork/migratingto2)

For GraphQL over HTTP, see the [GraphQL guide](GRAPHQL.md). For architectural details and contribution
instructions, see [ARCHITECTURE.md](ARCHITECTURE.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## Versioning

SwiftyNetwork follows [Semantic Versioning](https://semver.org). Public enums gain new cases only in a major
release, so exhaustive switches remain source-compatible across minor and patch releases. Extensible values such
as `HTTPMethod` and `RedirectPolicy` are structs.

## License and Support

SwiftyNetwork is available under the [MIT license](LICENSE). For questions or issues, use
[GitHub Discussions](https://github.com/maniramezan/SwiftyNetwork/discussions) or
[GitHub Issues](https://github.com/maniramezan/SwiftyNetwork/issues).
