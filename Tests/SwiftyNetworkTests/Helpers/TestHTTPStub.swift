import Foundation
import TestCommons

final class TestHTTPStub: Sendable {
    struct Response: Sendable {
        let outcome: Result<StubResponse, any Error>

        static func success(_ data: Data, statusCode: Int = 200) -> Response {
            Response(outcome: .success(StubResponse(statusCode: statusCode, body: data)))
        }

        static func status(_ code: Int, data: Data = Data()) -> Response {
            success(data, statusCode: code)
        }

        static func failure(_ error: any Error) -> Response {
            Response(outcome: .failure(error))
        }
    }

    private let responses = TestValueBox<[String: ScriptedValues<Response>]>([:])
    private let stub: StubbedURLSession

    init() throws {
        let responses = responses
        stub = try StubbedURLSession { request in
            let id = Self.testID(in: request) ?? "__default"
            let response = try responses.withValue { scripts in
                guard var script = scripts[id] else {
                    throw URLError(.badServerResponse)
                }
                defer { scripts[id] = script }
                return try script.next()
            }
            return try response.outcome.get()
        }
    }

    var session: URLSession { stub.session }
    var requests: [URLRequest] { stub.requests }

    func setResponses(_ values: [Response], for id: String) {
        responses.withValue { $0[id] = ScriptedValues(values) }
    }

    func getLastRequestHeaders(for id: String) -> [String: String]? {
        requests.last { Self.testID(in: $0) == id }?.allHTTPHeaderFields
    }

    func invalidate() { stub.invalidate() }

    private static func testID(in request: URLRequest) -> String? {
        request.url.flatMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "test-id" }?.value
        }
    }
}
