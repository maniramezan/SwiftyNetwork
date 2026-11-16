# Securing connections

Pin certificates for hosts you operate with ``SSLPinningConfiguration``, and control how redirects carry credentials with ``RedirectPolicy``.

## Overview

Both protections are per client. Pinning is opt-in and applies to the hosts you list; the redirect
policy applies to every request and defaults to stripping credentials across origins.

## Pinning certificates

Use SSL pinning when your app and API are operated together and you can safely rotate pins before server
certificates or keys change. Pinning is enforced only for configured hosts; all other hosts use normal
`URLSession` trust handling.

```swift
enum PinConfigurationError: Error {
    case invalidPin
}

func makePinnedClient() throws -> NetworkClient {
    guard let apiPublicKeyPin = SSLPinningConfiguration.Pin.publicKeySHA256(
        base64Encoded: "BASE64_ENCODED_SHA256_PUBLIC_KEY_HASH"
    ) else {
        throw PinConfigurationError.invalidPin
    }

    let pinning = SSLPinningConfiguration(
        pinnedHosts: [
            "api.example.com": [apiPublicKeyPin]
        ],
        includesSubdomains: false,
        requiresDefaultTrustValidation: true
    )

    let configuration = NetworkClientConfiguration(
        session: pinning.makeSession(),
        timeout: .seconds(30)
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

## Redirects

``NetworkClient`` checks every redirect against `NetworkClientConfiguration.redirectPolicy` before
`URLSession` follows it. The default, `.stripCredentialsAcrossOrigins`, does what `curl` and browser `fetch` do:

- A redirect within the same origin (scheme, host, and port) is followed unchanged.
- A redirect to another origin is followed without the `Authorization`, `Proxy-Authorization`, and `Cookie`
  headers, or the header an `.apiKey` or `.custom` authorization set.
- A redirect from `https` to plain `http` is refused.

A refused redirect throws `NetworkError.unexpectedStatus` with the `3xx` response, so you can read its
`Location` header. Use `.never` for an API that should not redirect at all, or `.followAll` to let `URLSession`
follow every redirect with its headers, as 1.x did:

```swift
let configuration = NetworkClientConfiguration(redirectPolicy: .never)
```

Your own redirect handling always wins. If the session you inject has a delegate that implements
`urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`, ``NetworkClient`` hands every redirect
to it and uses its answer unchanged, under any policy, so that delegate must remove credentials itself. A
session delegate that doesn't handle redirects, such as the TLS pinning one, leaves them to the policy.

Credentials sent under another header name through an endpoint's `headers` are not recognized; send them
through an ``AuthorizationType`` so they are stripped.
