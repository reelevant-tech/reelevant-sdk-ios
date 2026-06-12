import Foundation

// MARK: - Personalization types

extension ReelevantAnalytics {

    /// Fallback strategy when a runner call fails or times out.
    public enum FallbackStrategy {
        /// Return an empty result (default). Your UI renders its default state.
        case empty
        /// Re-throw the underlying error.
        case error
        /// Provide a custom handler that produces a fallback result.
        case custom((_ options: RunOptions, _ error: Error) -> RunResult)
    }

    /// Options for a single workflow run.
    public struct RunOptions {
        public let workflowId: String
        public let entrypoint: String
        /// Override user identity. `nil` = auto-resolve from stored identity.
        public var userId: String?
        /// URL parameters forwarded to the runner.
        public var params: [String: String]?
        /// Locale for content resolution.
        public var locale: String?
        /// Per-call timeout override in seconds.
        public var timeout: TimeInterval?

        public init(
            workflowId: String,
            entrypoint: String,
            userId: String? = nil,
            params: [String: String]? = nil,
            locale: String? = nil,
            timeout: TimeInterval? = nil
        ) {
            self.workflowId = workflowId
            self.entrypoint = entrypoint
            self.userId = userId
            self.params = params
            self.locale = locale
            self.timeout = timeout
        }
    }

    /// Discriminated content returned by the runner.
    public enum RunContent {
        case html(String)
        case json([String: Any])
        case image(Data)
        case empty
    }

    /// Where the result came from.
    public enum RunSource {
        case runner
        case fallback
    }

    /// Typed result returned by `run()`.
    public struct RunResult {
        /// HTTP status code from the runner response (0 for fallback/timeout).
        public let status: Int
        public let source: RunSource
        /// Typed content — switch on this to handle each content type.
        public let body: RunContent
        /// Metadata from x-rlvt-output-node-metadata header.
        public let metadata: [String: Any]
        /// Properties from x-rlvt-output-properties header.
        public let properties: [String: Any]
        /// Workflow run ID for tracking correlation.
        public let runId: String?
        /// Execution path (branch IDs).
        public let executionPath: [String]
        /// Pre-built click-through URL (runner with mode=click).
        public let redirectionUrl: String
        /// Fire-and-forget click tracking closure.
        internal let _trackClick: () -> Void

        public init(
            status: Int,
            source: RunSource,
            body: RunContent,
            metadata: [String: Any],
            properties: [String: Any],
            runId: String?,
            executionPath: [String],
            redirectionUrl: String,
            trackClick: @escaping () -> Void = {}
        ) {
            self.status = status
            self.source = source
            self.body = body
            self.metadata = metadata
            self.properties = properties
            self.runId = runId
            self.executionPath = executionPath
            self.redirectionUrl = redirectionUrl
            self._trackClick = trackClick
        }
    }

    /// Errors specific to personalization runner calls.
    public enum RunnerCallError: Error, LocalizedError {
        case timeout(TimeInterval)
        case httpError(status: Int, body: String)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .timeout(let t): return "Runner call timed out after \(t)s"
            case .httpError(let s, _): return "Runner returned HTTP \(s)"
            case .invalidResponse: return "Invalid runner response"
            }
        }
    }
}

// MARK: - Internal runner helpers

private let sdkVersion = "ios-0.1.0"

internal func executeRunnerCall(
    options: ReelevantAnalytics.RunOptions,
    runnerUrl: String,
    timeout: TimeInterval,
    userId: String,
    completion: @escaping (Result<ReelevantAnalytics.RunResult, Error>) -> Void
) {
    let effectiveTimeout = options.timeout ?? timeout
    let urlString = buildRunnerUrlString(runnerUrl: runnerUrl, options: options, userId: userId)
    let redirectionUrl = buildRedirectionUrlString(runnerUrl: runnerUrl, options: options, userId: userId)

    guard let url = URL(string: urlString) else {
        completion(.failure(ReelevantAnalytics.RunnerCallError.invalidResponse))
        return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = effectiveTimeout
    request.setValue(sdkVersion, forHTTPHeaderField: "x-rlvt-sdk-version")

    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorTimedOut {
                completion(.failure(ReelevantAnalytics.RunnerCallError.timeout(effectiveTimeout)))
            } else {
                completion(.failure(error))
            }
            return
        }

        guard let httpResponse = response as? HTTPURLResponse, let data = data else {
            completion(.failure(ReelevantAnalytics.RunnerCallError.invalidResponse))
            return
        }

        let statusCode = httpResponse.statusCode
        guard (200...299).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            completion(.failure(ReelevantAnalytics.RunnerCallError.httpError(status: statusCode, body: body)))
            return
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        let runId = httpResponse.value(forHTTPHeaderField: "x-rlvt-workflow-run-id")
        let executionPathHeader = httpResponse.value(forHTTPHeaderField: "x-rlvt-execution-path")
        let metadataHeader = httpResponse.value(forHTTPHeaderField: "x-rlvt-output-node-metadata")
        let propertiesHeader = httpResponse.value(forHTTPHeaderField: "x-rlvt-output-properties")

        let executionPath = executionPathHeader?.components(separatedBy: ",") ?? []
        let metadata = metadataHeader.flatMap { safeJsonParseDictionary($0) } ?? [:]
        let properties = propertiesHeader.flatMap { safeJsonParseDictionary($0) } ?? [:]
        let body = parseResponseBody(data: data, contentType: contentType)

        let capturedTimeout = effectiveTimeout
        let result = ReelevantAnalytics.RunResult(
            status: statusCode,
            source: .runner,
            body: body,
            metadata: metadata,
            properties: properties,
            runId: runId,
            executionPath: executionPath,
            redirectionUrl: redirectionUrl,
            trackClick: { fireAndForgetClick(url: redirectionUrl, timeout: capturedTimeout) }
        )
        completion(.success(result))
    }
    task.resume()
}

internal func fireAndForgetClick(url urlString: String, timeout: TimeInterval) {
    guard let url = URL(string: urlString) else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = timeout
    request.setValue(sdkVersion, forHTTPHeaderField: "x-rlvt-sdk-version")
    // Don't follow redirects — we just need the runner to register the click
    let config = URLSessionConfiguration.default
    let session = URLSession(configuration: config, delegate: NoRedirectDelegate.shared, delegateQueue: nil)
    let task = session.dataTask(with: request) { _, _, _ in /* fire-and-forget */ }
    task.resume()
}

// MARK: - Async wrappers (iOS 13+)

@available(iOS 13.0, macOS 10.15, *)
internal func executeRunnerCallAsync(
    options: ReelevantAnalytics.RunOptions,
    runnerUrl: String,
    timeout: TimeInterval,
    userId: String
) async throws -> ReelevantAnalytics.RunResult {
    try await withCheckedThrowingContinuation { continuation in
        executeRunnerCall(options: options, runnerUrl: runnerUrl, timeout: timeout, userId: userId) { result in
            continuation.resume(with: result)
        }
    }
}

// MARK: - Private helpers

private class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirectDelegate()
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private func buildRunnerUrlString(
    runnerUrl: String,
    options: ReelevantAnalytics.RunOptions,
    userId: String
) -> String {
    var components = URLComponents(string: "\(runnerUrl)/\(options.workflowId)/\(options.entrypoint)")!
    var items = [URLQueryItem(name: "rlvt-u", value: userId)]
    if let locale = options.locale {
        items.append(URLQueryItem(name: "locale", value: locale))
    }
    options.params?.forEach { key, value in
        items.append(URLQueryItem(name: key, value: value))
    }
    components.queryItems = items
    return components.url!.absoluteString
}

private func buildRedirectionUrlString(
    runnerUrl: String,
    options: ReelevantAnalytics.RunOptions,
    userId: String
) -> String {
    var components = URLComponents(string: "\(runnerUrl)/\(options.workflowId)/\(options.entrypoint)")!
    components.queryItems = [
        URLQueryItem(name: "rlvt-u", value: userId),
        URLQueryItem(name: "mode", value: "click")
    ]
    return components.url!.absoluteString
}

private func parseResponseBody(data: Data, contentType: String) -> ReelevantAnalytics.RunContent {
    if contentType.contains("text/html") {
        guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .empty
        }
        return .html(text)
    }

    if contentType.contains("image/") {
        return data.isEmpty ? .empty : .image(data)
    }

    if contentType.contains("application/json") {
        return parseJsonBody(data: data)
    }

    // Unknown content-type: try JSON, fall back to HTML
    let jsonResult = parseJsonBody(data: data)
    if case .empty = jsonResult {
        guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .empty
        }
        return .html(text)
    }
    return jsonResult
}

private func parseJsonBody(data: Data) -> ReelevantAnalytics.RunContent {
    guard let text = String(data: data, encoding: .utf8),
          !text.trimmingCharacters(in: .whitespaces).isEmpty else {
        return .empty
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return .empty
    }
    return .json(json)
}

private func safeJsonParseDictionary(_ str: String) -> [String: Any]? {
    guard let data = str.data(using: .utf8),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return dict
}
