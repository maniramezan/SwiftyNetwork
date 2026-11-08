import Foundation

/// Parses the HTTP `Retry-After` response header (RFC 9110 §10.2.3).
///
/// The header carries either a non-negative number of seconds (delta-seconds)
/// or an HTTP-date. Both forms are normalized to a `Duration` measured
/// from the moment the response was received.
enum RetryAfter {
    /// The header field name.
    static let headerName = "Retry-After"

    /// Parses a raw `Retry-After` header value.
    ///
    /// - Parameters:
    ///   - value: The raw header value, e.g. `"5"` or `"Wed, 21 Oct 2015 07:28:00 GMT"`.
    ///   - now: The reference instant for the HTTP-date form. Overridable for tests.
    /// - Returns: The delay, never negative (a date in the past yields `.zero`),
    ///   or `nil` when the value is malformed.
    static func parse(_ value: String, now: Date = Date()) -> Duration? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) {
            guard let seconds = Int64(trimmed) else { return nil }
            return .seconds(seconds)
        }

        guard let date = parseHTTPDate(trimmed) else { return nil }
        return .seconds(max(0, date.timeIntervalSince(now)))
    }

    /// Accepts the three HTTP-date formats servers may send (RFC 9110 §5.6.7).
    private static func parseHTTPDate(_ value: String) -> Date? {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy",
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }
}
