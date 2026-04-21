import Foundation

struct CodexCredentials: Sendable {
    let accessToken: String
    let accountId: String?
}

enum CodexAuthReader {
    static func loadCredentials() -> CodexCredentials? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let authURL = home.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: authURL) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty
        else { return nil }
        let accountId = tokens["account_id"] as? String
        return CodexCredentials(accessToken: accessToken, accountId: accountId)
    }
}
