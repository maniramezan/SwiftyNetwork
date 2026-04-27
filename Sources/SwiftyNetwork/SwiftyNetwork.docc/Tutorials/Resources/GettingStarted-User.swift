import Foundation

struct User: Codable, Sendable {
    let id: String
    let name: String
    let email: String
}
