import SwiftyNetwork

public protocol AppErrorProtocol {
    var integrationMarker: String { get }
}

public func otherFrameworkHasError() -> Bool {
    let error = NetworkError.forbidden(HTTPResponse(statusCode: 403))
    return error.response?.statusCode == 403
}
