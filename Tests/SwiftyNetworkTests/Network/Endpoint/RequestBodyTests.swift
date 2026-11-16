import Foundation
import Testing

@testable import SwiftyNetwork

@Suite("Form and multipart request bodies")
struct RequestBodyTests {
    @Test("A form body percent-encodes names and values and writes spaces as plus signs")
    func formBodyEncoding() {
        let form = FormURLEncodedBody([
            URLQueryItem(name: "grant type", value: "refresh_token"),
            URLQueryItem(name: "q", value: "a+b&c=d/é~"),
            URLQueryItem(name: "tag", value: "one"),
            URLQueryItem(name: "tag", value: nil),
        ])

        let encoded = String(decoding: form.encoded(), as: UTF8.self)

        #expect(encoded == "grant+type=refresh_token&q=a%2Bb%26c%3Dd%2F%C3%A9%7E&tag=one&tag=")
    }

    @Test("An empty form body encodes to no bytes")
    func emptyFormBody() {
        #expect(FormURLEncodedBody().encoded().isEmpty)
    }

    @Test("A multipart body writes text and file parts in order, ending with the closing boundary")
    func multipartEncoding() {
        var form = MultipartFormData(boundary: "BOUNDARY")
        form.append("Profile photo", name: "caption")
        form.append(Data([0xFF, 0xD8]), name: "file", fileName: "avatar.jpg", mimeType: "image/jpeg")

        var expected = Data(
            """
            --BOUNDARY\r
            Content-Disposition: form-data; name="caption"\r
            \r
            Profile photo\r
            --BOUNDARY\r
            Content-Disposition: form-data; name="file"; filename="avatar.jpg"\r
            Content-Type: image/jpeg\r
            \r

            """.utf8)
        expected.append(Data([0xFF, 0xD8]))
        expected.append(Data("\r\n--BOUNDARY--\r\n".utf8))

        #expect(form.encoded() == expected)
        #expect(form.contentType == "multipart/form-data; boundary=BOUNDARY")
    }

    @Test("An empty multipart body is only the closing boundary")
    func emptyMultipart() {
        let form = MultipartFormData(boundary: "B")

        #expect(form.isEmpty)
        #expect(form.encoded() == Data("--B--\r\n".utf8))
    }

    @Test("Quotes and line breaks in names cannot end the parameter or add a header")
    func multipartEscapesHeaderParameters() {
        var form = MultipartFormData(boundary: "B")
        form.append(Data(), name: "a\"b", fileName: "x\r\nEvil: 1.txt", mimeType: "text/plain\r\nEvil: 2")

        let encoded = String(decoding: form.encoded(), as: UTF8.self)

        #expect(encoded.contains("name=\"a%22b\"; filename=\"x%0D%0AEvil: 1.txt\"\r\n"))
        #expect(encoded.contains("Content-Type: text/plainEvil: 2\r\n"))
        #expect(!encoded.contains("\r\nEvil"))
    }

    @Test("Each form gets its own boundary by default")
    func defaultBoundariesAreUnique() {
        #expect(MultipartFormData().boundary != MultipartFormData().boundary)
    }

    @Test("An endpoint sends a multipart body and its content type through the client")
    func multipartThroughClient() async throws {
        struct Upload: NetworkEndpoint {
            let form: MultipartFormData
            let baseURL = "https://api.test.com"
            let path = "/avatar"
            let method: HTTPMethod = .post
            var headers: [String: String]? { ["Content-Type": form.contentType] }
            var body: Data? { form.encoded() }
        }
        var form = MultipartFormData(boundary: "B")
        form.append("hello", name: "caption")

        let request = try Upload(form: form).makeURLRequest()

        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=B")
        #expect(request.httpBody == form.encoded())
    }
}
