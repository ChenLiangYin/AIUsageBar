import Foundation

struct OAuthUsageWindow: Sendable {
    // API returns utilization as a number on the 0–100 scale (e.g. `16` means
    // 16%). Values can come back as JSON integers, so decode via asDouble.
    let utilization: Double?
    let resetsAt: Date?
}

struct OAuthUsageResponse: Sendable {
    let fiveHour: OAuthUsageWindow?
    let sevenDay: OAuthUsageWindow?
}

enum OAuthFetchError: Error {
    case unauthorized
    case http(Int)
    case network(Error)
    case decode
}

enum ClaudeOAuthClient {
    private static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let betaHeader = "oauth-2025-04-20"
    private static let userAgent = "claude-code/2.1.0"

    static func fetchUsage(accessToken: String) async throws -> OAuthUsageResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OAuthFetchError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OAuthFetchError.decode
        }
        switch http.statusCode {
        case 200:
            return try decode(data)
        case 401:
            throw OAuthFetchError.unauthorized
        default:
            throw OAuthFetchError.http(http.statusCode)
        }
    }

    private static func decode(_ data: Data) throws -> OAuthUsageResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthFetchError.decode
        }
        let fiveHour = window(from: obj["five_hour"] as? [String: Any])
        let sevenDay = window(from: obj["seven_day"] as? [String: Any])
        return OAuthUsageResponse(fiveHour: fiveHour, sevenDay: sevenDay)
    }

    private static func window(from dict: [String: Any]?) -> OAuthUsageWindow? {
        guard let dict else { return nil }
        let raw = dict["utilization"]
        let utilization: Double? = {
            // JSONSerialization returns ints as NSNumber; NSNull sentinel as NSNull.
            if let n = raw as? NSNumber, !(raw is NSNull) { return n.doubleValue }
            if let d = raw as? Double { return d }
            if let i = raw as? Int { return Double(i) }
            return nil
        }()
        let resetsAt = (dict["resets_at"] as? String).flatMap(parseISO)
        return OAuthUsageWindow(utilization: utilization, resetsAt: resetsAt)
    }
}

private func parseISO(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}
