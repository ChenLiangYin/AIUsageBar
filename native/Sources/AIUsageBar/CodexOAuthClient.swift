import Foundation

struct CodexWindow: Sendable {
    let usedPercent: Double       // 0–100 scale (API field `used_percent`)
    let resetAt: Date?            // API returns seconds-since-epoch
    let limitWindowSeconds: Int?
}

struct CodexUsageResponse: Sendable {
    let planType: String?
    let primaryWindow: CodexWindow?
    let secondaryWindow: CodexWindow?
}

enum CodexFetchError: Error {
    case unauthorized
    case http(Int)
    case network(Error)
    case decode
}

enum CodexOAuthClient {
    // Undocumented ChatGPT backend endpoint; also what CodexBar uses.
    private static let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    static func fetchUsage(credentials: CodexCredentials) async throws -> CodexUsageResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsageBar", forHTTPHeaderField: "User-Agent")
        if let id = credentials.accountId, !id.isEmpty {
            request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CodexFetchError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CodexFetchError.decode
        }
        switch http.statusCode {
        case 200...299:
            return try decode(data)
        case 401, 403:
            throw CodexFetchError.unauthorized
        default:
            throw CodexFetchError.http(http.statusCode)
        }
    }

    private static func decode(_ data: Data) throws -> CodexUsageResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexFetchError.decode
        }
        let plan = obj["plan_type"] as? String
        let rate = obj["rate_limit"] as? [String: Any]
        let primary = window(from: rate?["primary_window"] as? [String: Any])
        let secondary = window(from: rate?["secondary_window"] as? [String: Any])
        return CodexUsageResponse(
            planType: plan,
            primaryWindow: primary,
            secondaryWindow: secondary
        )
    }

    private static func window(from dict: [String: Any]?) -> CodexWindow? {
        guard let dict else { return nil }
        let used: Double? = asDouble(dict["used_percent"])
        let reset: Date? = {
            if let secs = asDouble(dict["reset_at"]), secs > 0 {
                // Some ChatGPT endpoints return seconds, others milliseconds —
                // normalize by magnitude.
                let s = secs > 2_000_000_000 ? secs / 1000 : secs
                return Date(timeIntervalSince1970: s)
            }
            return nil
        }()
        let windowSeconds = dict["limit_window_seconds"] as? Int
        guard let used else { return nil }
        return CodexWindow(usedPercent: used, resetAt: reset, limitWindowSeconds: windowSeconds)
    }

    private static func asDouble(_ v: Any?) -> Double? {
        if v is NSNull { return nil }
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String, let d = Double(s) { return d }
        return nil
    }
}
