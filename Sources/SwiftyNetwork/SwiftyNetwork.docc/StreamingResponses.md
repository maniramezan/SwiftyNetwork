# Streaming responses

Send a request ``NetworkClient`` cannot decode, such as Server-Sent Events, and keep its authorization and refresh.

## Overview

``NetworkClient`` decodes whole responses, so it cannot carry a Server-Sent Events stream.
``NetworkClient/sendAuthorized(_:operationName:errorBody:transport:)`` runs a raw
`URLRequest` through a transport you supply, with the client's authorization, `401` refresh-once, redirect policy, and
instrumentation, and throws the same ``NetworkError`` cases:

```swift
let (bytes, _) = try await client.sendAuthorized(request) { request, session, delegate in
    try await session.bytes(for: request, delegate: delegate)
} errorBody: { bytes in
    var body = Data()
    do { for try await byte in bytes { body.append(byte) } } catch {}
    return body
}
do {
    for try await line in bytes.lines {
        handle(line)
    }
} catch {
    // The client's work ends at the response headers; map stream errors the same way it does.
    throw NetworkError.mapTransportError(error)
}
```

It returns only for a `2xx`. It never retries transient failures and does not set a timeout. Instrumentation reports
the attempt as completed when the headers arrive. Use it only for your own API: the provider's credentials go to
any URL, so call `URLSession` directly for presigned or third-party URLs, and map its errors with
`NetworkError.mapTransportError(_:session:)`. Background sessions are not supported.
