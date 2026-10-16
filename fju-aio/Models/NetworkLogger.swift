import Foundation
import os.log

final class NetworkLogger: Sendable {
    nonisolated static let shared = NetworkLogger()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.nelsongx.apps.fju-aio", category: "Network")

    private init() {}

    nonisolated func logRequest(_ request: URLRequest) {
        logger.info("🌐 REQUEST: \(request.httpMethod ?? "GET", privacy: .public) \(Self.redactedDescription(of: request.url), privacy: .public)")
        #if DEBUG
        if let headers = request.allHTTPHeaderFields {
            logger.debug("📋 Headers: \(String(describing: headers), privacy: .private)")
        }
        if let body = request.httpBody, let bodyString = String(data: body, encoding: .utf8) {
            logger.debug("📦 Body: \(bodyString, privacy: .private)")
        }
        #endif
    }

    nonisolated func logResponse(_ response: URLResponse?, data: Data?, error: Error?) {
        if let error = error {
            logger.error("❌ ERROR: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            logger.warning("⚠️ Invalid response type")
            return
        }

        let statusEmoji = httpResponse.statusCode >= 200 && httpResponse.statusCode < 300 ? "✅" : "❌"
        logger.info("\(statusEmoji) RESPONSE: \(httpResponse.statusCode, privacy: .public) \(Self.redactedDescription(of: httpResponse.url), privacy: .public)")

        #if DEBUG
        if let headers = httpResponse.allHeaderFields as? [String: String] {
            logger.debug("📋 Response Headers: \(String(describing: headers), privacy: .private)")
        }

        if let data = data, let bodyString = String(data: data, encoding: .utf8) {
            logger.debug("📦 Response Body: \(bodyString, privacy: .private)")
        }
        #endif
    }

    // MARK: - Redaction

    /// `host/path` with CAS tickets (`TGT-…`, `ST-…`, `PGT-…`) in the path replaced and
    /// every query value dropped — only query parameter names are kept.
    nonisolated static func redactedDescription(of url: URL?) -> String {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "unknown"
        }

        let path = components.path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { isSensitivePathSegment($0) ? "<redacted>" : String($0) }
            .joined(separator: "/")

        var description = (components.host ?? "") + path
        if let queryItems = components.queryItems, !queryItems.isEmpty {
            description += "?" + queryItems.map { "\($0.name)=<redacted>" }.joined(separator: "&")
        }
        return description
    }

    private nonisolated static func isSensitivePathSegment(_ segment: Substring) -> Bool {
        segment.hasPrefix("TGT-") || segment.hasPrefix("ST-") || segment.hasPrefix("PGT-")
    }
}
