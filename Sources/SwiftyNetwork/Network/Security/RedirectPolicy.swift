import Foundation

/// How ``NetworkClient`` treats HTTP redirects.
///
/// `URLSession` follows redirects and, by default, copies the original request's
/// headers onto the redirected request, so a bearer token or API key would reach
/// whatever host the server redirects to. ``NetworkClient`` therefore checks every
/// redirect against ``NetworkClientConfiguration/redirectPolicy`` before it is followed.
///
/// The default, ``stripCredentialsAcrossOrigins``, matches what `curl` and browser
/// `fetch` do: a redirect within the same origin (scheme, host, and port) is followed
/// unchanged, a redirect to another origin is followed without credentials, and a
/// redirect from `https` to plain `http` is refused.
///
/// A refused redirect is not followed. The client receives the `3xx` response itself
/// and throws ``NetworkError/unexpectedStatus(_:)``, whose ``HTTPResponse`` carries the
/// `Location` header.
///
/// Your own redirect handling always wins. When the session in
/// ``NetworkClientConfiguration/session`` has a delegate that implements
/// `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)` (or its
/// `async` form), the client passes every redirect to that delegate and uses its answer
/// unchanged; the policy is not applied. Such a delegate is responsible for removing
/// credentials itself. A delegate that doesn't handle redirects, like the one from
/// ``SSLPinningConfiguration/makeSession(configuration:delegateQueue:)``, leaves them to
/// the policy.
///
/// Example:
/// ```swift
/// // Never follow redirects, for an API that should not redirect at all.
/// let configuration = NetworkClientConfiguration(redirectPolicy: .never)
/// ```
public struct RedirectPolicy: Sendable, Equatable {
    enum Behavior: Sendable, Equatable {
        case stripCredentialsAcrossOrigins
        case followAll
        case never
    }

    let behavior: Behavior

    private init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    /// Follows redirects, but removes credentials when the origin changes and refuses
    /// an `https` to `http` downgrade. This is the default.
    ///
    /// On a redirect to a different scheme, host, or port than the request the caller
    /// made, the client removes the `Authorization`, `Proxy-Authorization`, and `Cookie`
    /// headers, plus the header named by an ``AuthorizationType/apiKey(key:header:)`` or
    /// ``AuthorizationType/custom(header:value:)`` authorization. Credentials that an
    /// endpoint sends under any other header name through ``NetworkEndpoint/headers``
    /// are not recognized; use an ``AuthorizationType`` for them.
    public static let stripCredentialsAcrossOrigins = RedirectPolicy(.stripCredentialsAcrossOrigins)

    /// Leaves redirects to `URLSession`, as SwiftyNetwork 1.x did.
    ///
    /// `URLSession` follows every redirect with the original headers. Use this only when
    /// you trust every host your API can redirect to. You don't need it to keep your own
    /// session delegate's redirect handling: that runs under every policy.
    public static let followAll = RedirectPolicy(.followAll)

    /// Never follows a redirect; every `3xx` response surfaces as
    /// ``NetworkError/unexpectedStatus(_:)``, unless your session delegate handles
    /// redirects and follows it.
    public static let never = RedirectPolicy(.never)
}
