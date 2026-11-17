# Building requests

Add headers to every request, and send JSON, form, or multipart bodies.

## Overview

An endpoint describes one request: its URL, method, headers, and body. ``NetworkClient`` adds
what every request shares, such as default headers and authorization, before sending it.

### Add headers to every request

Set ``NetworkClientConfiguration/defaultHeaders`` for headers every request needs, such as a
language or an app version:

```swift
var configuration = NetworkClientConfiguration()
configuration.defaultHeaders = ["Accept-Language": "en-GB", "X-App-Version": "4.2.0"]
let client = NetworkClient(configuration: configuration)
```

A header set by the endpoint wins over a default with the same name, compared
case-insensitively. Default headers also apply to raw requests sent through
``NetworkClient/sendAuthorized(_:operationName:errorBody:transport:)``.

Don't put credentials in default headers. Authorization from an ``AuthorizationType`` or an
``AuthorizationProvider`` is applied after them, refreshed on a `401`, and stripped from
cross-origin redirects; a default header gets none of that.

### Send a JSON body

Pass an `Encodable` value with the request. The client encodes it with its configured
`JSONEncoder` and sets `Content-Type: application/json` unless the endpoint sets a
`Content-Type` of its own:

```swift
struct UpdateProfileEndpoint: NetworkEndpoint {
    let baseURL = "https://api.example.com"
    let path = "/me"
    let method: HTTPMethod = .patch
}

let saved = try await client.request(UpdateProfileEndpoint(), body: draft, responseType: User.self)
```

### Send a form body

OAuth token endpoints and HTML-style forms expect `application/x-www-form-urlencoded`. Build
the fields with ``FormURLEncodedBody`` and return its bytes and content type from the endpoint:

```swift
struct TokenEndpoint: NetworkEndpoint {
    let form: FormURLEncodedBody

    let baseURL = "https://auth.example.com"
    let path = "/oauth/token"
    let method: HTTPMethod = .post
    var usesAuthorizationProvider: Bool { false }
    var headers: [String: String]? { ["Content-Type": FormURLEncodedBody.contentType] }
    var body: Data? { form.encoded() }
}

let form = FormURLEncodedBody([
    URLQueryItem(name: "grant_type", value: "refresh_token"),
    URLQueryItem(name: "refresh_token", value: refreshToken),
])
let token = try await client.request(TokenEndpoint(form: form), responseType: Token.self)
```

Fields are encoded in order, and a name can repeat.

### Upload files with a multipart body

Use ``MultipartFormData`` to upload files alongside text fields. Its content type carries the
boundary, so take the header and the body from the same value:

```swift
struct UploadAvatarEndpoint: NetworkEndpoint {
    let form: MultipartFormData

    let baseURL = "https://api.example.com"
    let path = "/avatar"
    let method: HTTPMethod = .post
    var headers: [String: String]? { ["Content-Type": form.contentType] }
    var body: Data? { form.encoded() }
}

var form = MultipartFormData()
form.append("Profile photo", name: "caption")
form.append(jpegData, name: "file", fileName: "avatar.jpg", mimeType: "image/jpeg")
try await client.request(UploadAvatarEndpoint(form: form))
```

The whole body is held in memory, which suits images and documents up to a few megabytes. For
larger files, stream from disk with `URLSession.upload(for:fromFile:)` through
``NetworkClient/sendAuthorized(_:operationName:errorBody:transport:)``, as
<doc:StreamingResponses> shows for downloads.

## See Also

- ``NetworkEndpoint``
- ``NetworkClientConfiguration``
- ``FormURLEncodedBody``
- ``MultipartFormData``
