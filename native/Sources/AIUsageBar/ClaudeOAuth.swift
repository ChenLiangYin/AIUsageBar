import Foundation
import Security

struct OAuthCredentials: Sendable {
    let accessToken: String
    let rateLimitTier: String?
    let subscriptionType: String?
    let expiresAt: Date?
}

enum OAuthLoadError: Error {
    case notFound
    case decodeFailed
}

enum KeychainReader {
    static let service = "Claude Code-credentials"

    static func loadCredentials() throws -> OAuthCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw OAuthLoadError.notFound
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String
        else {
            throw OAuthLoadError.decodeFailed
        }
        let tier = oauth["rateLimitTier"] as? String
        let sub = oauth["subscriptionType"] as? String
        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double {
            expires = Date(timeIntervalSince1970: ms / 1000)
        } else if let ms = oauth["expiresAt"] as? Int64 {
            expires = Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        return OAuthCredentials(
            accessToken: access,
            rateLimitTier: tier,
            subscriptionType: sub,
            expiresAt: expires
        )
    }
}
