# GraphQL over HTTP

SwiftyNetwork can send ordinary JSON GraphQL POST requests through its existing
HTTP client. It does not generate schema types, normalize entity caches, or
implement subscriptions, multipart incremental responses, or persisted-query negotiation.

## Typed request and response

These application-owned types work with the configured JSON encoder and decoder:

```swift
import Foundation
import SwiftyNetwork

struct GraphQLEndpoint: NetworkEndpoint {
    let baseURL: String
    var path: String { "/graphql" }
    var method: HTTPMethod { .post }
    var headers: [String: String]? {
        ["Accept": "application/graphql-response+json, application/json"]
    }
}

struct GraphQLBody<Variables: Encodable & Sendable>: Encodable, Sendable {
    let query: String
    let operationName: String?
    let variables: Variables
}

struct GraphQLResponse<Value: Decodable & Sendable>: Decodable, Sendable {
    let data: Value?
    let errors: [GraphQLIssue]?
}

struct GraphQLIssue: Decodable, Sendable {
    let message: String
}

struct UserVariables: Encodable, Sendable {
    let id: String
}

struct UserSelection: Decodable, Sendable {
    let user: User?

    struct User: Decodable, Sendable {
        let id: String
        let name: String?
    }
}

func loadUser(client: NetworkClient, baseURL: String, id: String) async throws
    -> GraphQLResponse<UserSelection>
{
    try await client.request(
        GraphQLEndpoint(baseURL: baseURL),
        body: GraphQLBody(
            query: "query User($id: ID!) { user(id: $id) { id name } }",
            operationName: "User",
            variables: UserVariables(id: id)
        ),
        responseType: GraphQLResponse<UserSelection>.self
    )
}
```

Use variables for input values instead of interpolating them into query source.
Encoding failures propagate; avoid `try?` in an endpoint's computed body, which
can silently produce a bodyless request. Keep JSON coding strategies compatible
with schema field names and the `operationName` envelope key.

## Error and cache policy

A successful HTTP status does not imply a successful GraphQL operation. Inspect
`errors` and `data` together: partial data and execution errors can coexist.
Model nullable fields as optional. The minimal example reads error messages;
extend it with typed `locations`, mixed string/integer `path` components, and
server-specific `extensions` when the application needs those details.
See the [GraphQL response specification](https://spec.graphql.org/September2025/#sec-Response).

Non-2xx responses follow `NetworkError` mapping before GraphQL decoding. Some
status mappings retain the body in `serverError`; others do not. Applications
requiring every GraphQL error envelope, regardless of HTTP status, need a raw
response transport API, which this package does not yet provide. Media types and
status semantics are described by the [GraphQL over HTTP draft](https://github.com/graphql/graphql-over-http/blob/main/spec/GraphQLOverHTTP.md).

Cache keys must include operation, variables, and account/tenant identity. Decide
whether a partial result is cacheable before storing it. The generic repository
will cache a successfully decoded envelope even if it contains GraphQL errors.
Likewise, `MutationQueue` does not inspect GraphQL errors in HTTP 200 responses;
use an application adapter that validates the envelope before reporting success.
Retries require server-side idempotency for mutations. Never log raw variables,
error messages, or response bodies without application-specific redaction.
