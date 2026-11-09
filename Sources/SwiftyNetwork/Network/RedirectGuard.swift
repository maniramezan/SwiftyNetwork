import Foundation

/// A per-task delegate that applies a ``RedirectPolicy`` to one request.
///
/// Passed to `URLSession.data(for:delegate:)`. It implements only the redirect
/// callback, so a session delegate (for example the one from
/// ``SSLPinningConfiguration/makeSession(configuration:delegateQueue:)``) still
/// handles authentication challenges.
///
/// A task delegate takes precedence over the session delegate, so this guard
/// forwards every redirect to the session delegate when it implements the redirect
/// callback and returns that answer unchanged. The app's own redirect handling
/// always decides; the policy applies only to sessions without one.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    /// Headers that always carry credentials, matched case-insensitively.
    static let credentialHeaders = ["Authorization", "Proxy-Authorization", "Cookie"]

    /// The Objective-C selector of the redirect callback. The Swift `async` and
    /// completion-handler forms share it, so it detects either implementation.
    static let redirectSelector = NSSelectorFromString(
        "URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:"
    )

    private let behavior: RedirectPolicy.Behavior
    private let strippedHeaders: [String]

    /// Creates a guard, or returns `nil` when the policy leaves redirects to the session.
    ///
    /// - Parameters:
    ///   - policy: The client's redirect policy.
    ///   - authorization: The authorization applied to the request, whose header is
    ///     stripped along with ``credentialHeaders`` across origins.
    init?(policy: RedirectPolicy, authorization: AuthorizationType) {
        guard policy.behavior != .followAll else { return nil }
        behavior = policy.behavior
        var headers = Self.credentialHeaders
        if let header = authorization.headerName,
            !headers.contains(where: { $0.caseInsensitiveCompare(header) == .orderedSame })
        {
            headers.append(header)
        }
        strippedHeaders = headers
    }

    /// Implemented in completion-handler form so it runs on the session's delegate
    /// queue, where the session delegate expects to be called.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        if let sessionDelegate = session.delegate as? URLSessionTaskDelegate,
            sessionDelegate.responds(to: Self.redirectSelector)
        {
            Logger.debug("Redirect decided by the session delegate; the redirect policy is not applied")
            sessionDelegate.urlSession?(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: request,
                completionHandler: completionHandler
            )
            return
        }
        completionHandler(redirect(request, from: task.originalRequest?.url ?? response.url))
    }

    /// Decides what to do with a redirect.
    ///
    /// - Parameters:
    ///   - request: The redirected request `URLSession` proposes.
    ///   - source: The URL the caller originally requested.
    /// - Returns: The request to follow, or `nil` to stop and deliver the `3xx` response.
    func redirect(_ request: URLRequest, from source: URL?) -> URLRequest? {
        switch behavior {
        case .followAll:
            return request
        case .never:
            Logger.info("Redirect not followed: the redirect policy is .never")
            return nil
        case .stripCredentialsAcrossOrigins:
            guard let source, let target = request.url else {
                Logger.warning("Redirect not followed: missing source or target URL")
                return nil
            }
            if source.scheme?.lowercased() == "https", target.scheme?.lowercased() != "https" {
                Logger.warning("Redirect not followed: it downgrades HTTPS to an insecure scheme", category: .security)
                return nil
            }
            guard Origin(source) != Origin(target) else {
                return request
            }
            Logger.info("Following a cross-origin redirect without credentials", category: .security)
            var stripped = request
            for header in strippedHeaders {
                stripped.setValue(nil, forHTTPHeaderField: header)
            }
            return stripped
        }
    }
}

/// A URL's scheme, host, and effective port, compared case-insensitively.
struct Origin: Equatable {
    let scheme: String?
    let host: String?
    let port: Int?

    init(_ url: URL) {
        scheme = url.scheme?.lowercased()
        host = url.host()?.lowercased()
        port = url.port ?? Self.defaultPort(for: scheme)
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme {
        case "https": 443
        case "http": 80
        default: nil
        }
    }
}
