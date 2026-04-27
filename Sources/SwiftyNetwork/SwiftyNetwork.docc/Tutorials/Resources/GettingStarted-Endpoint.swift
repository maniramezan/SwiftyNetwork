import SwiftyNetwork

struct UserEndpoint: NetworkEndpoint {
    let baseURL = "https://api.example.com"
    let userId: String

    var path: String { "/users/\(userId)" }
    var method: HTTPMethod { .get }
    var headers: [String: String]? { ["Accept": "application/json"] }
}
