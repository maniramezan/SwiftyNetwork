import Foundation
import SwiftCommons

/// A thread-safe network client that handles HTTP requests with auth refresh on 401.
///
/// ``NetworkClient`` refreshes authorization once on 401 (up to
/// ``NetworkClientConfiguration/maxAuthRefreshAttempts``) and retries the
/// original request with the new credentials. It does not retry transient
/// failures unless you opt in with ``NetworkClientConfiguration/retryPolicy``,
/// which retries idempotent requests on `429`, 5xx, timeouts and lost
/// connectivity (see ``NetworkRetryPolicy``).
///
/// Example:
/// ```swift
/// struct User: Decodable, Sendable {
///     let id: String
///     let name: String
/// }
///
/// let client = NetworkClient()
/// let user = try await client.request(UserEndpoint(id: "123"), responseType: User.self)
/// ```
public actor NetworkClient: NetworkDataSource {

    private var configuration: NetworkClientConfiguration
    private var requestAttemptCount = 0

    /// Shared client with default configuration.
    ///
    /// Suitable for simple apps. For testability or multiple distinct
    /// configurations, create dedicated ``NetworkClient`` instances.
    ///
    /// Example:
    /// ```swift
    /// let user = try await NetworkClient.shared.request(endpoint, responseType: User.self)
    /// ```
    public static let shared = NetworkClient()

    /// Creates a new network client.
    ///
    /// Example:
    /// ```swift
    /// let configuration = NetworkClientConfiguration(timeoutInterval: 10, logLevel: .debug)
    /// let client = NetworkClient(configuration: configuration)
    /// ```
    ///
    /// - Parameter configuration: The configuration to use.
    public init(configuration: NetworkClientConfiguration = NetworkClientConfiguration()) {
        self.configuration = configuration
        if let logLevel = configuration.logLevel {
            Logger.setLevel(logLevel)
        }
    }

    /// Replaces the active configuration atomically.
    ///
    /// Existing in-flight requests continue with the configuration captured when
    /// they started. New requests use `newConfiguration`.
    ///
    /// Example:
    /// ```swift
    /// await client.updateConfiguration(NetworkClientConfiguration(logLevel: .info))
    /// ```
    ///
    /// - Parameter newConfiguration: The new configuration to apply.
    public func updateConfiguration(_ newConfiguration: NetworkClientConfiguration) {
        self.configuration = newConfiguration
        if let logLevel = newConfiguration.logLevel {
            Logger.setLevel(logLevel)
        }
    }

    /// Returns the cumulative number of request **attempts** made by this client,
    /// including retries triggered by auth refresh or ``NetworkClientConfiguration/retryPolicy``.
    ///
    /// Example:
    /// ```swift
    /// let attempts = await client.attemptCount()
    /// ```
    public func attemptCount() async -> Int {
        requestAttemptCount
    }

    // MARK: - Public Request API

    /// Performs a network request and decodes the response.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint describing the request.
    ///   - responseType: The expected `Decodable` response type.
    /// - Returns: A decoded value of `responseType`.
    /// - Throws: ``NetworkError`` if the request, response, or decoding fails.
    ///
    /// Example:
    /// ```swift
    /// let profile = try await client.request(ProfileEndpoint(), responseType: Profile.self)
    /// ```
    public func request<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        responseType: T.Type
    ) async throws -> T {
        let configuration = self.configuration
        return try await performRequest(
            endpoint,
            responseType: responseType,
            refreshAttempt: 0,
            retryAttempt: 0,
            configuration: configuration,
            requestID: UUID()
        )
    }

    /// Performs a network request with an `Encodable` body, encoding it via the
    /// configured `JSONEncoder`.
    ///
    /// A `Content-Type: application/json` header is added automatically unless
    /// the endpoint already declares a `Content-Type` header.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint describing the request.
    ///   - body: The value to encode as the request body.
    ///   - responseType: The expected `Decodable` response type.
    /// - Returns: A decoded value of `responseType`.
    /// - Throws: ``NetworkError/encodingFailed(underlying:)`` if encoding fails;
    ///   other ``NetworkError`` cases on transport or decoding failures.
    ///
    /// Example:
    /// ```swift
    /// let draft = CreatePostRequest(title: "Hello", body: "...")
    /// let post = try await client.request(CreatePostEndpoint(), body: draft, responseType: Post.self)
    /// ```
    public func request<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        body: Body,
        responseType: T.Type
    ) async throws -> T {
        let configuration = self.configuration
        let encodedBody = try await Self.encodeBody(body, encoder: configuration.encoder)

        let wrapped = EncodedBodyEndpoint(wrapped: endpoint, encodedBody: encodedBody)
        return try await performRequest(
            wrapped,
            responseType: responseType,
            refreshAttempt: 0,
            retryAttempt: 0,
            configuration: configuration,
            requestID: UUID()
        )
    }

    // MARK: - Private Request Pipeline

    private func performRequest<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        responseType: T.Type,
        refreshAttempt: Int,
        retryAttempt: Int,
        configuration: NetworkClientConfiguration,
        requestID: UUID
    ) async throws -> T {
        requestAttemptCount += 1
        let attempt = refreshAttempt + retryAttempt + 1
        Logger.debug("Starting request (attempt \(attempt))")

        let url = try EndpointURLBuilder.url(
            baseURL: endpoint.baseURL,
            path: endpoint.path,
            queryItems: endpoint.queryItems
        )
        Logger.debugURL("Resolved URL", url: url)

        var trace = RequestTrace(
            instrumentation: configuration.instrumentation,
            requestID: requestID,
            url: url,
            method: endpoint.method,
            attempt: attempt
        )
        await trace.start()

        var request = endpoint.makeUnauthenticatedURLRequest(url: url)
        request.timeoutInterval = configuration.timeoutInterval
        let providerAuthorization = await applyAuthorization(
            to: &request,
            from: endpoint,
            configuration: configuration
        )

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            (data, httpResponse) = try await send(request, session: configuration.session)
        } catch let error as NetworkError {
            return try await retryOrFail(
                error,
                endpoint: endpoint,
                responseType: responseType,
                refreshAttempt: refreshAttempt,
                retryAttempt: retryAttempt,
                configuration: configuration,
                trace: trace
            )
        }

        if httpResponse.statusCode == 401 {
            return try await handleUnauthorized(
                endpoint: endpoint,
                responseType: responseType,
                refreshAttempt: refreshAttempt,
                retryAttempt: retryAttempt,
                rejectedAuthorization: providerAuthorization,
                response: HTTPErrorResponse(httpResponse, body: data),
                configuration: configuration,
                trace: trace
            )
        }

        do {
            try HTTPStatusValidator.validate(
                statusCode: httpResponse.statusCode,
                data: data,
                retryAfter: RetryAfter.parse(from: httpResponse),
                response: Self.errorResponse(for: httpResponse, body: data)
            )
            let decoded = try await Self.decodeResponse(
                data: data,
                responseType: responseType,
                decoder: configuration.decoder
            )
            await trace.completed(statusCode: httpResponse.statusCode)
            return decoded
        } catch let error as NetworkError {
            return try await retryOrFail(
                error,
                endpoint: endpoint,
                responseType: responseType,
                refreshAttempt: refreshAttempt,
                retryAttempt: retryAttempt,
                configuration: configuration,
                trace: trace
            )
        }
    }

    /// Retries the request when ``NetworkClientConfiguration/retryPolicy`` allows it;
    /// otherwise reports `error` to observers and rethrows it.
    ///
    /// The wait is a cancellable sleep, so cancelling the calling task ends the
    /// wait and surfaces `CancellationError`.
    private func retryOrFail<T: Decodable & Sendable>(
        _ error: NetworkError,
        endpoint: any NetworkEndpoint,
        responseType: T.Type,
        refreshAttempt: Int,
        retryAttempt: Int,
        configuration: NetworkClientConfiguration,
        trace: RequestTrace
    ) async throws -> T {
        guard let policy = configuration.retryPolicy,
            retryAttempt < policy.maxRetries,
            policy.shouldRetry(error, method: endpoint.method)
        else {
            await trace.failed(error)
            throw error
        }

        let delay = policy.delay(forRetry: retryAttempt + 1, after: error)
        Logger.info(
            "Retrying \(endpoint.method.rawValue) after \(error.classification) in \(delay)s "
                + "(retry \(retryAttempt + 1) of \(policy.maxRetries))"
        )
        if delay > 0 {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                // Cancelled while waiting: close out this attempt for observers.
                Logger.info("Retry wait cancelled")
                await trace.failed(.underlying(AnySendableError(error)))
                throw error
            }
        }

        await trace.retrying()

        return try await performRequest(
            endpoint,
            responseType: responseType,
            refreshAttempt: refreshAttempt,
            retryAttempt: retryAttempt + 1,
            configuration: configuration,
            requestID: trace.requestID
        )
    }

    /// Builds the response snapshot only for statuses whose errors carry one.
    private static func errorResponse(for httpResponse: HTTPURLResponse, body: Data) -> HTTPErrorResponse? {
        guard httpResponse.statusCode == 401 || httpResponse.statusCode == 403 else { return nil }
        return HTTPErrorResponse(httpResponse, body: body)
    }

    /// Executes `request`, mapping every transport failure to a ``NetworkError``.
    private func send(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            Logger.error("URL error during request", error: error)
            throw NetworkError.mapURLError(error)
        } catch {
            Logger.error("Unexpected error during request", error: error)
            throw NetworkError.underlying(AnySendableError(error))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        return (data, httpResponse)
    }

    /// Applies endpoint authorization, falling back to the configured provider
    /// when the endpoint declares ``AuthorizationType/none``.
    ///
    /// - Returns: The provider-supplied authorization that was applied, or `nil`
    ///   when the endpoint's own authorization was used. Only provider
    ///   authorization is eligible for refresh after a `401`.
    private func applyAuthorization(
        to request: inout URLRequest,
        from endpoint: any NetworkEndpoint,
        configuration: NetworkClientConfiguration
    ) async -> AuthorizationType? {
        if case .none = endpoint.authorization, let provider = configuration.authorizationProvider {
            let providerAuthorization = await provider.currentAuthorization()
            providerAuthorization.apply(to: &request)
            return providerAuthorization
        }
        endpoint.authorization.apply(to: &request)
        return nil
    }

    /// Encodes off the client actor, for the same reason as ``decodeResponse(data:responseType:decoder:)``.
    private static func encodeBody<Body: Encodable & Sendable>(
        _ body: Body,
        encoder: JSONEncoder
    ) async throws -> Data {
        do {
            return try encoder.encode(body)
        } catch {
            Logger.error("Failed to encode request body", error: error)
            throw NetworkError.encodingFailed(underlying: AnySendableError(error))
        }
    }

    /// Decodes off the client actor.
    ///
    /// A `static` async function is nonisolated, so it runs on the global
    /// concurrent executor. Large payloads therefore don't block other
    /// requests on this client from starting or finishing while they decode.
    private static func decodeResponse<T: Decodable & Sendable>(
        data: Data,
        responseType: T.Type,
        decoder: JSONDecoder
    ) async throws -> T {
        if data.isEmpty, responseType == EmptyResponse.self {
            guard let emptyResponse = EmptyResponse() as? T else {
                throw NetworkError.invalidData
            }
            return emptyResponse
        }

        do {
            let decoded = try decoder.decode(T.self, from: data)
            Logger.debug("Successfully decoded response as \(T.self)")
            return decoded
        } catch {
            if let decodingError = error as? DecodingError {
                // Debug-only: coding paths can include dictionary keys taken from the payload.
                Logger.debug("Decoding failure detail: \(decodingError.debugSummary)")
            }
            Logger.error("Failed to decode response as \(T.self)", error: error)
            throw NetworkError.decodingFailed(underlying: AnySendableError(error))
        }
    }

    private func handleUnauthorized<T: Decodable & Sendable>(
        endpoint: any NetworkEndpoint,
        responseType: T.Type,
        refreshAttempt: Int,
        retryAttempt: Int,
        rejectedAuthorization: AuthorizationType?,
        response: HTTPErrorResponse,
        configuration: NetworkClientConfiguration,
        trace: RequestTrace
    ) async throws -> T {
        guard let provider = configuration.authorizationProvider,
            let rejectedAuthorization,
            refreshAttempt < configuration.maxAuthRefreshAttempts
        else {
            Logger.warning("Cannot refresh authorization — no provider or max refresh attempts reached")
            let error = NetworkError.unauthorized(response: response)
            await trace.failed(error)
            throw error
        }

        guard await provider.shouldRefreshAuthorization(after: response) else {
            Logger.info("Authorization provider declined to refresh for this 401", category: .auth)
            let error = NetworkError.unauthorized(response: response)
            await trace.failed(error)
            throw error
        }

        Logger.info("Attempting to refresh authorization", category: .auth)
        guard await provider.refreshAuthorization(rejecting: rejectedAuthorization) else {
            Logger.error("Authorization refresh failed", category: .auth)
            await trace.failed(.authorizationRefreshFailed)
            throw NetworkError.authorizationRefreshFailed
        }
        Logger.info("Authorization refreshed successfully; retrying request", category: .auth)

        if configuration.authRefreshDelay > 0 {
            Logger.debug("Waiting \(configuration.authRefreshDelay)s before retry")
            do {
                try await Task.sleep(for: .seconds(configuration.authRefreshDelay))
            } catch {
                // Cancelled while waiting: close out this attempt for observers.
                await trace.failed(.underlying(AnySendableError(error)))
                throw error
            }
        }

        await trace.retrying()

        return try await performRequest(
            endpoint,
            responseType: responseType,
            refreshAttempt: refreshAttempt + 1,
            retryAttempt: retryAttempt,
            configuration: configuration,
            requestID: trace.requestID
        )
    }
}
