import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Low-level Ghost Admin API client for one site.
///
/// Handles auth, request limits, retries and error mapping. Resource methods
/// live in `GhostClient+Resources.swift`.
public final class GhostClient: Sendable {
    /// Sent as `Accept-Version`; Ghost uses it to pick API behaviour.
    public static let acceptVersion = "v6.0"
    static let userAgent = "Atelier/0.1"

    public let endpoint: SiteEndpoint
    public let limiter: RequestLimiter
    let signer: TokenSigner
    let transport: HTTPTransport
    let retryPolicy: RetryPolicy
    let sleep: @Sendable (Duration) async throws -> Void

    public init(
        endpoint: SiteEndpoint,
        key: AdminAPIKey,
        transport: HTTPTransport = URLSessionTransport(),
        limiter: RequestLimiter = RequestLimiter(),
        retryPolicy: RetryPolicy = RetryPolicy(),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.endpoint = endpoint
        self.signer = TokenSigner(key: key)
        self.transport = transport
        self.limiter = limiter
        self.retryPolicy = retryPolicy
        self.sleep = sleep
    }

    public enum Method: String, Sendable {
        case get = "GET", post = "POST", put = "PUT", delete = "DELETE"
    }

    /// Sends a request and returns the response body, retrying transient failures.
    ///
    /// Retrying a `PUT` is safe for posts: if the first attempt was applied but
    /// its response lost, the retry fails with `.conflict`, which callers
    /// resolve by re-reading the item.
    public func send(_ method: Method, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        let request = try makeRequest(method, path, query: query, body: body)
        var attempt = 1
        while true {
            do {
                return try await sendOnce(request)
            } catch let error as GhostError where error.isTransient && attempt < retryPolicy.maxAttempts {
                var delay = retryPolicy.delay(forRetry: attempt)
                if case .rateLimited(let retryAfter?) = error {
                    delay = max(delay, .seconds(retryAfter))
                }
                try await sleep(delay)
                attempt += 1
            }
        }
    }

    private func sendOnce(_ request: URLRequest) async throws -> Data {
        await limiter.acquire()
        do {
            var request = request
            request.setValue("Ghost \(signer.token())", forHTTPHeaderField: "Authorization")
            let (data, response): (Data, HTTPURLResponse)
            do {
                (data, response) = try await transport.send(request)
            } catch let error as GhostError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw GhostError.transport(String(describing: error))
            }
            if let error = Self.error(for: response, data: data) {
                if case .rateLimited(let retryAfter) = error {
                    await limiter.coolDown(for: .seconds(retryAfter ?? 5))
                }
                throw error
            }
            await limiter.release()
            return data
        } catch {
            await limiter.release()
            throw error
        }
    }

    func makeRequest(_ method: Method, _ path: String, query: [URLQueryItem], body: Data?) throws -> URLRequest {
        let url = endpoint.adminAPIURL.appendingPathComponent(path, isDirectory: true)
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GhostError.invalidSiteURL(url.absoluteString)
        }
        if !query.isEmpty { components.queryItems = query }
        // URLComponents leaves `+` unescaped, but servers decode it as a space;
        // NQL uses `+` for AND, so it must be sent as %2B.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let finalURL = components.url else { throw GhostError.invalidSiteURL(url.absoluteString) }

        var request = URLRequest(url: finalURL)
        request.httpMethod = method.rawValue
        request.setValue(Self.acceptVersion, forHTTPHeaderField: "Accept-Version")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    static func error(for response: HTTPURLResponse, data: Data) -> GhostError? {
        let status = response.statusCode
        guard !(200..<300).contains(status) else { return nil }
        let errors = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.errors ?? []
        if errors.contains(where: { $0.type == "UpdateCollisionError" }) {
            return .conflict(errors: errors)
        }
        switch status {
        case 401, 403: return .unauthorized(errors: errors)
        case 404: return .notFound(errors: errors)
        case 409: return .conflict(errors: errors)
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            return .rateLimited(retryAfter: retryAfter)
        default: return .http(status: status, errors: errors)
        }
    }

    private struct ErrorBody: Decodable {
        let errors: [GhostAPIError]
    }
}

// MARK: - JSON

extension GhostClient {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = parseDate(text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date: \(text)")
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Ghost returns ISO 8601 timestamps, usually with milliseconds.
    static func parseDate(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try Self.decoder.decode(type, from: data)
        } catch {
            throw GhostError.decoding(String(describing: error))
        }
    }
}
