# Handling errors and retries

Tell failures apart with ``NetworkError``, choose what to show, and retry the ones a retry can fix.

## Overview

Every failure is a ``NetworkError``. HTTP statuses each get their own case, so a rejected request (4xx),
a failing server (5xx), and a device that is offline never look alike:

| Case | When |
| --- | --- |
| `unauthorized`, `forbidden`, `notFound`, `tooManyRequests` | `401`, `403`, `404`, `429` |
| `clientError` | Any other `4xx`, such as `400`, `409`, or `422` |
| `serverError` | Any `5xx` |
| `unexpectedStatus` | A non-2xx status outside 4xx and 5xx, such as a `3xx` the redirect policy refused |
| `timeout` | A `408`, or a transport timeout (no response) |
| `noInternetConnection` | The device is offline or the connection dropped |
| `serverUnreachable` | DNS could not resolve the host or the server refused the connection |

```swift
do {
    let user = try await client.request(endpoint, responseType: User.self)
} catch NetworkError.unauthorized {
    // Handle authentication error
} catch NetworkError.clientError(let response) {
    // The server rejected the request, for example a validation error
} catch NetworkError.serverError(let response) {
    // Handle server error with response.statusCode
} catch NetworkError.noInternetConnection {
    // Offline
} catch NetworkError.decodingFailed(let underlying) {
    // Handle JSON decoding error
} catch {
    // Handle other errors
}
```

Every HTTP case carries the rejected ``HTTPResponse`` (only a transport `timeout` has none). Read its
status, headers, and body to tell apart failures that share a status code, such as an API error `code` in
the body, the `WWW-Authenticate` challenge, or `X-RateLimit-*` headers. `error.response` and
`error.statusCode` give the same values without a `switch`:

```swift
struct APIErrorBody: Decodable { let code: String }

do {
    let user = try await client.request(endpoint, responseType: User.self)
} catch NetworkError.forbidden(let response) {
    let apiError = try? response.decodeBody(APIErrorBody.self)
    if apiError?.code == "registration_required" {
        showRegistration()
    }
} catch NetworkError.unauthorized(let response) {
    let challenge = response.wwwAuthenticate
}
```

`catch NetworkError.unauthorized` without a binding still matches. Construct these errors in test doubles
as `NetworkError.notFound(HTTPResponse(statusCode: 404))`. The body is raw server data and
may contain user information, so don't log it. ``HTTPResponse`` prints only its status code, header names,
and body size, so interpolating it, or an error that carries it, into a log line doesn't leak header values or body.

Use `NetworkError.isTransient` (or `classification` for telemetry tags) to decide whether a retry could help.
Timeouts, lost connectivity, unreachable hosts, `429`, and 5xx statuses count as transient. This is the same rule
``NetworkRetryPolicy`` and `MutationRetryPolicy.default` use.

Cancelling the calling task always surfaces as `CancellationError`, whether it lands while the request is on
the wire, during a retry wait, or during an auth refresh. It is never wrapped in a ``NetworkError``:

```swift
do {
    let user = try await client.request(endpoint, responseType: User.self)
} catch is CancellationError {
    // The view went away; nothing to show
}
```

## Choosing What to Show

`error.category` collapses the cases into what a UI treats differently, the same grouping as
`MutationFailureReason.category`. `authorizationUnavailable` counts as `unauthorized`; use `error.classification`
to tell it apart from a `401`. The exception is a provider that failed only because the device lost connectivity:
when its error, or an error in its `NSUnderlyingErrorKey` chain, is a lost connection, unreachable host or timeout,
the error is classified as that failure, so the UI shows it as offline instead of asking the user to sign in again.

```swift
switch error.category {
case .offline, .serverUnreachable, .timedOut: showOfflineBanner()
case .unauthorized: promptSignIn()
case .rateLimited: showTryAgainLater(after: error.retryAfter)
case .insecureConnection: showInsecureConnectionError()
case .rejected, .serverError, .other: showGenericError()
}
```

`.insecureConnection` covers an untrusted certificate, a failed TLS handshake, and a rejected certificate pin, which
`URLSession` reports as `URLError.cancelled`.

## Rate Limiting (429) and Retry-After

A `429 Too Many Requests` response is reported as `NetworkError.tooManyRequests(_:)`, never as
`.clientError`. `HTTPResponse.retryAfter` is the parsed `Retry-After` header as a `Duration` (both the
delta-seconds and HTTP-date forms; `nil` if absent or malformed), `body` keeps the response body (empty if the
server sent none) so you can decode a problem+json document, and the headers keep values such as
`X-RateLimit-Remaining`. A `503 Service Unavailable` carries `retryAfter` on `.serverError` the same way:

```swift
do {
    _ = try await client.request(endpoint, responseType: User.self)
} catch NetworkError.tooManyRequests(let response) {
    let throttle = try? response.decodeBody(Problem.self)
    showBanner("Slow down", retryIn: response.retryAfter)
}
```

`error.retryAfter` gives the same value without a `switch`.

## Retrying Idempotent Requests

``NetworkClient`` never retries transient failures by default. Opt in with a ``NetworkRetryPolicy``:

```swift
let configuration = NetworkClientConfiguration(
    retryPolicy: NetworkRetryPolicy(
        maxRetries: 2,
        backoff: BackoffPolicy(baseDelay: .milliseconds(500), maxDelay: .seconds(8), maxRetryAfter: .seconds(30))
    )
)
let client = NetworkClient(configuration: configuration)
```

- `GET`, `HEAD`, `PUT`, `DELETE`, and `OPTIONS` are idempotent by default. `POST`, `PATCH`, and custom methods are not.
  An endpoint may opt an operation such as a server-deduplicated sync `POST` into retries with `isIdempotent`.
- Retried failures: `429`, 5xx, timeouts, lost connectivity, and unreachable hosts. Other 4xx responses and decoding failures
  are reported immediately.
- Waits follow a ``BackoffPolicy``: exponential with jitter, capped at `maxDelay`. A `429` or `503` `Retry-After` is
  honored (the wait is at least that long) and clamped to `maxRetryAfter`, so a huge value can't park a request.
- Waits are cancellation-aware: cancelling the calling task ends the wait with `CancellationError`.
- `maxRetries` bounds the retries after the first attempt, independently of `maxAuthRefreshAttempts`.
  Each retry emits `requestRetried` to your ``NetworkInstrumentation``.

If the client sits behind a ``MutationQueue``, its ``MutationRetryPolicy`` also retries; enabling both makes
the attempts multiply, so prefer one. Both policies have the same shape: `maxRetries` counts retries after the
first attempt, `backoff` is a ``BackoffPolicy``, and `shouldRetry` decides which failures are retried.
`MutationRetryPolicy.defaultBackoff` honors `Retry-After` up to 300s, so a throttled mutation waits as long as the
server asked instead of failing.
