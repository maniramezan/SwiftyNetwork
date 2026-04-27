import SwiftyNetwork

struct WeatherEndpoint: NetworkEndpoint {
    let baseURL = "https://api.example.com"
    var path: String { "/weather" }
    var method: HTTPMethod { .get }
    var authorization: AuthorizationType {
        .apiKey(key: "your-api-key", header: "X-API-Key")
    }
}
