import Foundation

/// Wraps any `Error` so it can be carried as `any Error & Sendable` in
/// ``NetworkError`` cases without requiring callers to declare Sendable
/// conformance on their own error types.
///
/// Only the error's descriptions are retained. Errors that are already
/// `Sendable` (such as `URLError`) should be stored directly instead so callers
/// can still pattern-match on them.
struct AnySendableError: Error, Sendable, CustomStringConvertible {
    let description: String
    let localizedDescriptionValue: String

    init(_ error: any Error) {
        self.description = String(describing: error)
        self.localizedDescriptionValue = error.localizedDescription
    }

    var localizedDescription: String { localizedDescriptionValue }
}
