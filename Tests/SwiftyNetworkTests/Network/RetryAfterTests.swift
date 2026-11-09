import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("RetryAfter Parsing Tests")
struct RetryAfterTests {
    private let now = Date(timeIntervalSince1970: 1_445_412_000)

    @Test("Parses delta-seconds")
    func parsesDeltaSeconds() {
        #expect(RetryAfter.parse("5", now: now) == .seconds(5))
        #expect(RetryAfter.parse("0", now: now) == .seconds(0))
        #expect(RetryAfter.parse("  120 ", now: now) == .seconds(120))
    }

    @Test("Parses the IMF-fixdate HTTP-date form relative to now")
    func parsesIMFFixdate() {
        // 1_445_412_000 is Wed, 21 Oct 2015 07:20:00 GMT.
        #expect(RetryAfter.parse("Wed, 21 Oct 2015 07:28:00 GMT", now: now) == .seconds(480))
    }

    @Test("Parses the obsolete RFC 850 and asctime HTTP-date forms")
    func parsesObsoleteDateForms() {
        #expect(RetryAfter.parse("Wednesday, 21-Oct-15 07:21:00 GMT", now: now) == .seconds(60))
        #expect(RetryAfter.parse("Wed Oct 21 07:22:00 2015", now: now) == .seconds(120))
    }

    @Test("An HTTP-date in the past yields zero")
    func pastDateYieldsZero() {
        #expect(RetryAfter.parse("Wed, 21 Oct 2015 07:00:00 GMT", now: now) == .seconds(0))
    }

    @Test("Malformed values yield nil")
    func malformedValuesYieldNil() {
        #expect(RetryAfter.parse("", now: now) == nil)
        #expect(RetryAfter.parse("soon", now: now) == nil)
        #expect(RetryAfter.parse("-5", now: now) == nil)
        #expect(RetryAfter.parse("1.5", now: now) == nil)
        #expect(RetryAfter.parse("5s", now: now) == nil)
        #expect(RetryAfter.parse("Wed, 99 Foo 2015 07:28:00 GMT", now: now) == nil)
    }

    @Test("HTTPResponse reads the header case-insensitively for 429 and 503 only")
    func errorResponseParsesRetryAfterForRateLimitStatuses() throws {
        let url = try #require(URL(string: "https://api.test.com/users"))
        let tooMany = try #require(
            HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["retry-after": "7"])
        )
        let unavailable = try #require(
            HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": "3"])
        )
        let teapot = try #require(
            HTTPURLResponse(url: url, statusCode: 418, httpVersion: nil, headerFields: ["Retry-After": "3"])
        )
        let without = try #require(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: [:]))

        #expect(HTTPResponse(tooMany, body: Data()).retryAfter == .seconds(7))
        #expect(HTTPResponse(unavailable, body: Data()).retryAfter == .seconds(3))
        #expect(HTTPResponse(teapot, body: Data()).retryAfter == nil)
        #expect(HTTPResponse(without, body: Data()).retryAfter == nil)
    }
}
