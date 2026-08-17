import Foundation

// MARK: - Remote Data Cache

/// A URL-keyed cache for raw response bodies (e.g. image bytes), with
/// per-key single-flight deduplication.
///
/// `RemoteDataCache` is a thin, convenience-focused composition of primitives
/// SwiftyNetwork already provides -- it is not a new storage mechanism. It
/// wraps whatever ``Cache`` you supply (an `InMemoryCache<Data>` for
/// memory-only, a `LayeredCache<Data>` for memory + disk, or your own
/// ``PersistentCache`` conformance) in a ``SingleFlightCache``, and adds a
/// `data(for:)` convenience that fetches via `URLSession` on a miss.
///
/// Size limits, eviction policy, and persistence are entirely controlled by
/// the `Wrapped` cache you construct it with -- there is no hardcoded global
/// cache or built-in size limit. Configure it however your app needs:
///
/// ```swift
/// // Memory-only, LRU-bounded to 200 entries.
/// let imageCache = RemoteDataCache(cache: InMemoryCache<Data>(maxSize: 200))
///
/// // Memory + your own disk-backed PersistentCache.
/// let imageCache = RemoteDataCache(
///     cache: LayeredCache(memoryCache: InMemoryCache<Data>(maxSize: 200), persistentCache: myDiskCache)
/// )
///
/// let data = try await imageCache.data(for: imageURL)
/// ```
///
/// Concurrent calls for the same URL before the first completes share a
/// single fetch rather than issuing duplicate network requests.
public actor RemoteDataCache<Wrapped: Cache> where Wrapped.Value == Data {
    private let cache: SingleFlightCache<Wrapped>
    private let session: URLSession

    /// Creates a remote data cache.
    ///
    /// - Parameters:
    ///   - cache: Where fetched bytes are stored. Determines memory/disk
    ///     layering, size limits, and eviction policy -- see the type-level
    ///     documentation for examples.
    ///   - session: The URL session used to fetch on a cache miss. Defaults to `.shared`.
    public init(cache: Wrapped, session: URLSession = .shared) {
        self.cache = SingleFlightCache(cache)
        self.session = session
    }

    /// Returns the cached bytes for `url`, fetching and caching them on a miss.
    ///
    /// Concurrent calls for the same `url` before the first fetch completes
    /// share that single fetch instead of each issuing their own request.
    ///
    /// - Parameter url: The URL to fetch bytes from.
    /// - Returns: The cached or freshly fetched response body.
    /// - Throws: ``NetworkError/invalidResponse`` if the server response
    ///   isn't an HTTP response; ``NetworkError/serverError(statusCode:data:)``
    ///   for a non-2xx status; ``NetworkError/timeout``,
    ///   ``NetworkError/noInternetConnection``, or ``NetworkError/underlying(_:)``
    ///   for transport failures.
    public func data(for url: URL) async throws -> Data {
        let key = CacheKey(url: url)
        return try await cache.value(forKey: key) { [session] in
            try await Self.fetch(url, session: session)
        }
    }

    /// Returns the cached bytes for `url` without triggering a fetch on a miss.
    ///
    /// - Parameter url: The URL to look up.
    /// - Returns: The cached bytes, or `nil` if not cached.
    public func cachedData(for url: URL) async -> Data? {
        await cache.value(forKey: CacheKey(url: url))
    }

    /// Removes any cached bytes for `url`, cancelling an in-flight fetch for it if one exists.
    ///
    /// - Parameter url: The URL to evict.
    public func removeValue(for url: URL) async {
        await cache.removeValue(forKey: CacheKey(url: url))
    }

    /// Removes every cached value and cancels all in-flight fetches.
    public func removeAll() async {
        await cache.removeAll()
    }

    private static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch let error as URLError {
            throw NetworkError.mapURLError(error)
        } catch {
            throw NetworkError.underlying(AnySendableError(error))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw NetworkError.serverError(statusCode: httpResponse.statusCode, data: data)
        }
        return data
    }
}
