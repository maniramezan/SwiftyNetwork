import AppFramework
import OtherFramework
@_spi(Testing) import SwiftyNetwork
import Testing

@Test("Errors thrown across frameworks have one SwiftyNetwork type identity")
func networkErrorIdentity() throws {
    #expect(throws: NetworkError.self) {
        try throwAppError()
    }

    let error = try #require(throws: (any Error).self) {
        try throwAppError()
    }
    #expect(error is NetworkError)
    let appError = try #require(error as? any AppErrorProtocol)
    #expect(appError.integrationMarker == "shared")

    let localError: any Error = NetworkError.forbidden(HTTPResponse(statusCode: 403))
    let localAppError = localError as? any AppErrorProtocol
    #expect(localAppError?.integrationMarker == "shared")

    let provider = TestAuthorizationProvider(current: .none, refreshResult: true)
    _ = provider
}
