import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("RetryAfter Parsing Tests")
struct RetryAfterTests {
    private let now = Date(timeIntervalSince1970: 1_445_412_000)

    @Test("Parses delta-seconds")
    func parsesDeltaSeconds() {
        #expect(RetryAfter.parse("5", now: now) == 5)
        #expect(RetryAfter.parse("0", now: now) == 0)
        #expect(RetryAfter.parse("  120 ", now: now) == 120)
    }

    @Test("Parses the IMF-fixdate HTTP-date form relative to now")
    func parsesIMFFixdate() {
        // 1_445_412_000 is Wed, 21 Oct 2015 07:20:00 GMT.
        #expect(RetryAfter.parse("Wed, 21 Oct 2015 07:28:00 GMT", now: now) == 480)
    }

    @Test("Parses the obsolete RFC 850 and asctime HTTP-date forms")
    func parsesObsoleteDateForms() {
        #expect(RetryAfter.parse("Wednesday, 21-Oct-15 07:21:00 GMT", now: now) == 60)
        #expect(RetryAfter.parse("Wed Oct 21 07:22:00 2015", now: now) == 120)
    }

    @Test("An HTTP-date in the past yields zero")
    func pastDateYieldsZero() {
        #expect(RetryAfter.parse("Wed, 21 Oct 2015 07:00:00 GMT", now: now) == 0)
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

    @Test("Reads the header from an HTTPURLResponse case-insensitively")
    func readsHeaderFromResponse() throws {
        let url = try #require(URL(string: "https://api.test.com/users"))
        let response = try #require(
            HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["retry-after": "7"])
        )
        let without = try #require(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: [:]))

        #expect(RetryAfter.parse(from: response) == 7)
        #expect(RetryAfter.parse(from: without) == nil)
    }
}
