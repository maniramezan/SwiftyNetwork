import Foundation

/// Shares one in-flight operation among concurrent callers that ask for the same key.
///
/// The first caller for a key starts `operation` in an unstructured task; callers that arrive
/// before it finishes await the same task. The task belongs to no single caller, so a
/// cancelled caller does not cancel it for the others.
actor FetchCoalescer<Value: Sendable> {
    private struct Flight {
        let id: UUID
        let task: Task<Value, any Error>
    }

    private var flights: [CacheKey: Flight] = [:]

    /// Runs `operation`, or joins the one already running for `key`.
    func run(for key: CacheKey, _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let flight = flights[key] {
            return try await flight.task.value
        }
        let id = UUID()
        let task = Task { try await operation() }
        flights[key] = Flight(id: id, task: task)
        defer {
            // A later flight for the key may have replaced this one only after it finished.
            if flights[key]?.id == id {
                flights[key] = nil
            }
        }
        return try await task.value
    }
}
