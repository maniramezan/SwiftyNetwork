import Foundation
import Synchronization

/// A `URLProtocol` that answers by host and path, issuing real redirects through
/// `wasRedirectedTo:` the way the HTTP loader does.
///
/// The redirected request copies every header of the original, which is how
/// `URLSession` itself builds the proposed request, so a test sees exactly what the
/// redirect policy removed. When a redirect is refused, the `3xx` response is
/// delivered as the final response, matching the HTTP loader.
///
/// Routes are keyed by host and path, so each test registers its own unique hosts
/// and owns its session from ``makeSession()``.
///
/// `@unchecked Sendable`: the class adds no stored properties to `URLProtocol`; its
/// shared state lives in the static `Mutex`es, and URL loading drives each instance
/// from one thread at a time.
final class RedirectingURLProtocol: URLProtocol, @unchecked Sendable {
    enum Route: Sendable {
        case redirect(to: URL, statusCode: Int = 302)
        case ok(Data)
    }

    private static let routes = Mutex<[String: Route]>([:])
    private static let recorded = Mutex<[String: [URLRequest]]>([:])

    /// Registers `route` for requests to `url`'s host and path.
    static func register(_ route: Route, for url: URL) {
        routes.withLock { $0[routeKey(url)] = route }
    }

    /// The requests received for `host`, in arrival order.
    static func requests(forHost host: String) -> [URLRequest] {
        recorded.withLock { $0[host] ?? [] }
    }

    /// Removes the routes and recordings for `hosts`.
    static func unregister(_ hosts: [String]) {
        routes.withLock { routes in
            routes = routes.filter { key, _ in !hosts.contains { key.hasPrefix($0 + "/") } }
        }
        recorded.withLock { recorded in hosts.forEach { recorded[$0] = nil } }
    }

    /// An ephemeral configuration whose requests are answered by this protocol.
    static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingURLProtocol.self]
        return configuration
    }

    /// An ephemeral session whose requests are answered by this protocol.
    ///
    /// - Parameter delegate: An optional session delegate, standing in for an app's own.
    static func makeSession(delegate: (any URLSessionDelegate)? = nil) -> URLSession {
        URLSession(configuration: makeConfiguration(), delegate: delegate, delegateQueue: nil)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host(),
            let route = Self.routes.withLock({ $0[Self.routeKey(url)] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        Self.recorded.withLock { $0[host.lowercased(), default: []].append(request) }

        switch route {
        case .redirect(let target, let statusCode):
            guard
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": target.absoluteString]
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            var redirected = request
            redirected.url = target
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .ok(let body):
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func routeKey(_ url: URL) -> String {
        (url.host()?.lowercased() ?? "") + url.path()
    }
}
