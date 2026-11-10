import Foundation
internal import SwiftCommons

extension NetworkClient {
    /// Sends a raw `URLRequest` through a transport you supply, with this client's authorization,
    /// refresh-once, redirect, and instrumentation behavior.
    ///
    /// Use it for transports ``NetworkClient`` cannot model, such as Server-Sent Events or other
    /// streaming responses read with `URLSession.bytes(for:delegate:)`, downloads, or uploads, to
    /// your own API. The client does for your request what it does for an endpoint request:
    ///
    /// 1. Asks the configured ``AuthorizationProvider`` for ``AuthorizationProvider/currentAuthorization()``
    ///    and applies it to a copy of `request`, replacing any header it sets. Without a provider,
    ///    `request` is sent unchanged. A provider that throws fails the call with
    ///    ``NetworkError/authorizationUnavailable(underlying:)`` and nothing is sent.
    /// 2. Calls `transport`, passing the URL session from the configuration and a per-task delegate that
    ///    enforces the ``NetworkClientConfiguration/redirectPolicy``. Pass both to the session call.
    /// 3. On a `401`, or a `403` the provider chooses to refresh, asks
    ///    ``AuthorizationProvider/shouldRefreshAuthorization(after:)``, then calls
    ///    ``AuthorizationProvider/refreshAuthorization(rejecting:)`` with the exact authorization it sent,
    ///    waits ``NetworkClientConfiguration/authRefreshDelay``, and sends the request again, up to
    ///    ``NetworkClientConfiguration/maxAuthRefreshAttempts`` times.
    /// 4. Reports each attempt to the configured ``NetworkInstrumentation``, tagged with `operationName`.
    ///
    /// It returns only for a `2xx` response. Every other outcome throws what ``NetworkClient`` would
    /// throw for an endpoint request:
    ///
    /// | Outcome | Thrown |
    /// | --- | --- |
    /// | Provider has no authorization | ``NetworkError/authorizationUnavailable(underlying:)`` |
    /// | `401` and no refresh was possible, wanted, or left | ``NetworkError/unauthorized(_:)`` |
    /// | `401` and the refresh threw | ``NetworkError/authorizationRefreshFailed(underlying:)`` |
    /// | Other non-`2xx` status | E.g. ``NetworkError/notFound(_:)`` or ``NetworkError/serverError(_:)`` |
    /// | Offline or timeout | ``NetworkError/noInternetConnection`` or ``NetworkError/timeout(_:)`` |
    /// | Host unresolved or connection refused | ``NetworkError/serverUnreachable(_:)`` |
    /// | Other transport failure | ``NetworkError/underlying(_:)`` |
    /// | The calling task was cancelled | `CancellationError` |
    ///
    /// It never retries transient failures, because a stream that failed midway is not safe to replay
    /// blindly; ``NetworkClientConfiguration/retryPolicy`` does not apply. It does not set a timeout:
    /// the `timeoutInterval` of `request` is used, so set a long one for a stream.
    ///
    /// The client's work ends when the response headers arrive:
    ///
    /// - Instrumentation reports the attempt as completed then, not when you finish reading.
    /// - Errors thrown while you read a streamed payload come straight from `URLSession`. Map them with
    ///   ``NetworkError/mapTransportError(_:session:)`` to get the same ``NetworkError`` cases, as the
    ///   example below does.
    ///
    /// Send only requests to your own API's origin. The provider's credentials are applied to any URL,
    /// so a presigned upload or download URL, or another service's URL, would receive the user's
    /// token, and such services often reject a request that carries one. Call `URLSession` directly for
    /// those, and map its errors with ``NetworkError/mapTransportError(_:session:)``. Background
    /// `URLSession`s are not supported, because they don't support the async methods or per-task
    /// delegates this call relies on.
    ///
    /// Example, a Server-Sent Events stream that survives an expired token:
    /// ```swift
    /// var request = URLRequest(url: eventsURL)
    /// request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    ///
    /// let (bytes, _) = try await client.sendAuthorized(request) { request, session, delegate in
    ///     try await session.bytes(for: request, delegate: delegate)
    /// } errorBody: { bytes in
    ///     var body = Data()
    ///     do { for try await byte in bytes { body.append(byte) } } catch {}
    ///     return body
    /// }
    /// do {
    ///     for try await line in bytes.lines {
    ///         handle(line)
    ///     }
    /// } catch {
    ///     throw NetworkError.mapTransportError(error)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - request: The request to send. Its URL must be set.
    ///   - operationName: A stable name for instrumentation events, like
    ///     ``NetworkEndpoint/operationName``. Defaults to `nil`.
    ///   - errorBody: Reads the body of a non-`2xx` response from the payload, so the thrown
    ///     ``NetworkError`` carries it in ``HTTPResponse/body`` and ``AuthorizationProvider`` can
    ///     inspect a `401` body in ``AuthorizationProvider/shouldRefreshAuthorization(after:)``.
    ///     It runs only for a failing response. When `nil`, the body is empty.
    ///   - transport: Performs one attempt. Return the transport's result and its response. Errors
    ///     it throws are mapped like ``NetworkClient`` maps `URLSession` errors; a ``NetworkError``
    ///     passes through unchanged.
    /// - Returns: The transport's payload and the `2xx` response it came with.
    /// - Throws: A ``NetworkError`` as described above, or `CancellationError`.
    public func sendAuthorized<Payload: Sendable>(
        _ request: URLRequest,
        operationName: String? = nil,
        errorBody: (@Sendable (Payload) async -> Data)? = nil,
        transport:
            @Sendable (URLRequest, URLSession, (any URLSessionTaskDelegate)?) async throws -> (
                Payload, URLResponse
            )
    ) async throws -> (payload: Payload, response: HTTPURLResponse) {
        let configuration = self.configuration
        guard let url = request.url else {
            throw NetworkError.invalidURL(url: "")
        }
        let method = HTTPMethod(rawValue: request.httpMethod ?? HTTPMethod.get.rawValue)
        let requestID = UUID()
        var refreshAttempt = 0

        while true {
            var trace = RequestTrace(
                instrumentation: configuration.instrumentation,
                requestID: requestID,
                url: url,
                method: method,
                attempt: refreshAttempt + 1,
                operationName: operationName
            )
            await trace.start()
            Logger.debug("Starting raw request (attempt \(trace.attempt))")

            var authorizedRequest = request
            let providerAuthorization: AuthorizationType?
            do {
                providerAuthorization = try await applyProviderAuthorization(
                    to: &authorizedRequest,
                    configuration: configuration
                )
            } catch is CancellationError {
                Logger.info("Authorization lookup cancelled", category: .auth)
                await trace.failed(.underlying(CancellationError()))
                throw CancellationError()
            } catch {
                Logger.error("Authorization provider could not supply authorization", error: error, category: .auth)
                let failure = NetworkError.authorizationUnavailable(underlying: error)
                await trace.failed(failure)
                throw failure
            }

            let redirectGuard = RedirectGuard(
                policy: configuration.redirectPolicy,
                authorization: providerAuthorization ?? .none
            )
            let payload: Payload
            let urlResponse: URLResponse
            do {
                (payload, urlResponse) = try await transport(authorizedRequest, configuration.session, redirectGuard)
            } catch {
                let mapped = NetworkError.transportError(error, session: configuration.session)
                if let networkError = mapped as? NetworkError {
                    Logger.error("Transport error during raw request", error: error)
                    await trace.failed(networkError)
                } else {
                    Logger.info("Raw request cancelled")
                    await trace.failed(.underlying(AnySendableError(mapped)))
                }
                throw mapped
            }

            guard let httpResponse = urlResponse as? HTTPURLResponse else {
                await trace.failed(.invalidResponse)
                throw NetworkError.invalidResponse
            }

            if (200..<300).contains(httpResponse.statusCode) {
                await trace.completed(statusCode: httpResponse.statusCode)
                return (payload, httpResponse)
            }

            let body = await errorBody?(payload) ?? Data()
            let response = HTTPResponse(httpResponse, body: body)
            guard
                Self.isAuthorizationRejection(
                    statusCode: httpResponse.statusCode,
                    providerAuthorization: providerAuthorization
                )
            else {
                let failure = HTTPStatusValidator.error(for: response)
                await trace.failed(failure)
                throw failure
            }

            do {
                try await refreshAfterUnauthorized(
                    response: response,
                    rejectedAuthorization: providerAuthorization,
                    refreshAttempt: refreshAttempt,
                    configuration: configuration
                )
            } catch let error as NetworkError {
                await trace.failed(error)
                throw error
            } catch {
                await trace.failed(.underlying(AnySendableError(error)))
                throw error
            }

            await trace.retrying()
            refreshAttempt += 1
        }
    }

    /// Applies the configured provider's authorization, or leaves `request` unchanged without one.
    ///
    /// - Returns: The authorization that was applied, or `nil` when there is no provider.
    private func applyProviderAuthorization(
        to request: inout URLRequest,
        configuration: NetworkClientConfiguration
    ) async throws -> AuthorizationType? {
        guard let provider = configuration.authorizationProvider else { return nil }
        let authorization = try await provider.currentAuthorization()
        authorization.apply(to: &request)
        return authorization
    }
}
