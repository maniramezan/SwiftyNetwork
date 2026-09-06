import Foundation
import Testing

@testable import SwiftyNetwork

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

@Test("GraphQL recipe preserves partial data and errors")
func testGraphQLPartialResponse() throws {
    let json = Data(#"{"data":{"user":{"id":"1","name":null}},"errors":[{"message":"Name unavailable"}]}"#.utf8)
    let result = try JSONDecoder().decode(GraphQLResponse<UserSelection>.self, from: json)
    #expect(result.data?.user?.id == "1")
    #expect(result.data?.user?.name == nil)
    #expect(result.errors?.first?.message == "Name unavailable")
}

@Test("GraphQL recipe preserves errors-only responses")
func testGraphQLErrorsOnlyResponse() throws {
    let json = Data(#"{"errors":[{"message":"Invalid query"}]}"#.utf8)
    let result = try JSONDecoder().decode(GraphQLResponse<UserSelection>.self, from: json)
    #expect(result.data == nil)
    #expect(result.errors?.count == 1)
}

@Test("GraphQL variables remain JSON values rather than query source")
func testGraphQLVariablesEncoding() throws {
    let query = "query User($id: ID!) { user(id: $id) { id } }"
    let body = GraphQLBody(query: query, operationName: "User", variables: UserVariables(id: "quoted\"id"))
    let encoded = try JSONEncoder().encode(body)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["query"] as? String == query)
    #expect(object["operationName"] as? String == "User")
    #expect((object["variables"] as? [String: String])?["id"] == "quoted\"id")
}

@Test("Empty-response convenience works through APIClient")
func testProtocolEmptyResponseConvenience() async throws {
    struct EmptyClient: APIClient {
        func request<T: Decodable & Sendable>(
            _ endpoint: any NetworkEndpoint, responseType: T.Type
        ) async throws -> T {
            #expect(responseType == EmptyResponse.self)
            return try JSONDecoder().decode(responseType, from: Data("{}".utf8))
        }
    }
    let client: any APIClient = EmptyClient()
    try await client.request(GraphQLEndpoint(baseURL: "https://example.com"))
}
