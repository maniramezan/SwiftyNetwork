import OtherFramework
import SwiftyNetwork

// swift-format-ignore: AvoidRetroactiveConformances
extension NetworkError: @retroactive AppErrorProtocol {
    public var integrationMarker: String { "shared" }
}

public func throwAppError() throws {
    throw NetworkError.forbidden(HTTPResponse(statusCode: 403))
}
