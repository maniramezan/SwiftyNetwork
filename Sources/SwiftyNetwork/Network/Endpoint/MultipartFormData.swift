import Foundation

/// A `multipart/form-data` request body, for uploading files alongside text fields.
///
/// Build the parts, then return the bytes and content type from an endpoint. The content type
/// carries the boundary, so take both from the same value:
///
/// ```swift
/// struct UploadAvatarEndpoint: NetworkEndpoint {
///     let form: MultipartFormData
///
///     let baseURL = "https://api.example.com"
///     let path = "/avatar"
///     let method: HTTPMethod = .post
///     var headers: [String: String]? { ["Content-Type": form.contentType] }
///     var body: Data? { form.encoded() }
/// }
///
/// var form = MultipartFormData()
/// form.append("Profile photo", name: "caption")
/// form.append(jpegData, name: "file", fileName: "avatar.jpg", mimeType: "image/jpeg")
/// try await client.request(UploadAvatarEndpoint(form: form))
/// ```
///
/// The whole body is held in memory, which suits images and documents up to a few megabytes.
/// For larger files, stream from disk with `URLSession.upload(for:fromFile:)` through
/// ``NetworkClient/sendAuthorized(_:operationName:errorBody:transport:)``.
public struct MultipartFormData: Sendable, Equatable {
    private struct Part: Sendable, Equatable {
        let name: String
        let fileName: String?
        let mimeType: String?
        let data: Data
    }

    /// The delimiter between parts. It must not occur in any part's data.
    public let boundary: String

    private var parts: [Part] = []

    /// Creates an empty form.
    ///
    /// - Parameter boundary: The delimiter between parts. Defaults to a unique value, which you
    ///   only need to replace to get reproducible bytes in a test.
    public init(boundary: String = "SwiftyNetwork-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    /// The `Content-Type` header value for this body, including its boundary.
    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// Whether the form has no parts.
    public var isEmpty: Bool {
        parts.isEmpty
    }

    /// Adds a text field.
    ///
    /// - Parameters:
    ///   - value: The field's value, sent as UTF-8.
    ///   - name: The field's name.
    public mutating func append(_ value: String, name: String) {
        parts.append(Part(name: name, fileName: nil, mimeType: nil, data: Data(value.utf8)))
    }

    /// Adds a file or other binary field.
    ///
    /// - Parameters:
    ///   - data: The field's bytes.
    ///   - name: The field's name.
    ///   - fileName: The file name to report to the server, or `nil` to send none.
    ///   - mimeType: The media type of `data`. Defaults to `application/octet-stream`.
    public mutating func append(
        _ data: Data,
        name: String,
        fileName: String? = nil,
        mimeType: String = "application/octet-stream"
    ) {
        parts.append(Part(name: name, fileName: fileName, mimeType: mimeType, data: data))
    }

    /// Encodes the parts in the order they were added.
    ///
    /// - Returns: The body bytes.
    public func encoded() -> Data {
        var body = Data()
        for part in parts {
            var disposition = "Content-Disposition: form-data; name=\"\(Self.escape(part.name))\""
            if let fileName = part.fileName {
                disposition += "; filename=\"\(Self.escape(fileName))\""
            }
            body.append(Data("--\(boundary)\r\n\(disposition)\r\n".utf8))
            if let mimeType = part.mimeType {
                body.append(Data("Content-Type: \(Self.sanitize(mimeType))\r\n".utf8))
            }
            body.append(Data("\r\n".utf8))
            body.append(part.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    /// Escapes the characters that would end a quoted header parameter or start a new header,
    /// as browsers do for field and file names.
    private static func escape(_ parameter: String) -> String {
        parameter
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "\"", with: "%22")
    }

    /// Removes line breaks, so a media type cannot add headers to its part.
    private static func sanitize(_ headerValue: String) -> String {
        headerValue.filter { !$0.isNewline }
    }
}
