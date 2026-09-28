import Foundation

/// A thread-safe network client that handles HTTP requests with auth refresh on 401.
///
/// ``NetworkClient`` does not perform general retries on transient errors. It
/// will, however, refresh authorization once on 401 (up to
/// ``NetworkClientConfiguration/maxAuthRefreshAttempts``) and retry the
/// original request with the new credentials.
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
    /// including retries triggered by auth refresh.
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
            configuration: configuration,
            requestID: UUID()
        )
    }

    // MARK: - Private Request Pipeline

    private func performRequest<T: Decodable & Sendable>(
        _ endpoint: any NetworkEndpoint,
        responseType: T.Type,
        refreshAttempt: Int,
        configuration: NetworkClientConfiguration,
        requestID: UUID
    ) async throws -> T {
        requestAttemptCount += 1
        let attempt = refreshAttempt + 1
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
            await trace.failed(error)
            throw error
        }

        if httpResponse.statusCode == 401 {
            return try await handleUnauthorized(
                endpoint: endpoint,
                responseType: responseType,
                refreshAttempt: refreshAttempt,
                rejectedAuthorization: providerAuthorization,
                configuration: configuration,
                trace: trace
            )
        }

        do {
            try HTTPStatusValidator.validate(statusCode: httpResponse.statusCode, data: data)
            let decoded = try await Self.decodeResponse(
                data: data,
                responseType: responseType,
                decoder: configuration.decoder
            )
            await trace.completed(statusCode: httpResponse.statusCode)
            return decoded
        } catch let error as NetworkError {
            await trace.failed(error)
            throw error
        }
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
            Logger.error("Failed to decode response", error: error)
            throw NetworkError.decodingFailed(underlying: AnySendableError(error))
        }
    }

    private func handleUnauthorized<T: Decodable & Sendable>(
        endpoint: any NetworkEndpoint,
        responseType: T.Type,
        refreshAttempt: Int,
        rejectedAuthorization: AuthorizationType?,
        configuration: NetworkClientConfiguration,
        trace: RequestTrace
    ) async throws -> T {
        guard let provider = configuration.authorizationProvider,
            let rejectedAuthorization,
            refreshAttempt < configuration.maxAuthRefreshAttempts
        else {
            Logger.warning("Cannot refresh authorization — no provider or max refresh attempts reached")
            await trace.failed(.unauthorized)
            throw NetworkError.unauthorized
        }

        Logger.info("Attempting to refresh authorization", category: .auth)
        guard await provider.refreshAuthorization(rejecting: rejectedAuthorization) else {
            Logger.error("Authorization refresh failed", category: .auth)
            await trace.failed(.authorizationRefreshFailed)
            throw NetworkError.authorizationRefreshFailed
        }
        Logger.info("Authorization refreshed successfully; retrying request", category: .auth)

        if configuration.retryDelay > 0 {
            Logger.debug("Waiting \(configuration.retryDelay)s before retry")
            do {
                try await Task.sleep(for: .seconds(configuration.retryDelay))
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
            configuration: configuration,
            requestID: trace.requestID
        )
    }
}
