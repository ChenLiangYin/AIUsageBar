import Foundation
import LocalAuthentication
import Security

private let claudeCredentialCacheMaxAge: TimeInterval = 60

struct OAuthCredentials: Sendable {
    let accessToken: String
    let refreshToken: String?
    let rateLimitTier: String?
    let subscriptionType: String?
    let expiresAt: Date?
}

enum OAuthLoadError: Error {
    case notFound
    case decodeFailed
    case interactionNotAllowed
}

enum KeychainReader {
    static let service = "Claude Code-credentials"

    static func loadCredentials(allowUserInteraction: Bool = true) throws -> OAuthCredentials {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowUserInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status == errSecInteractionNotAllowed
                || status == errSecAuthFailed
                || status == errSecUserCanceled {
                throw OAuthLoadError.interactionNotAllowed
            }
            throw OAuthLoadError.notFound
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String
        else {
            throw OAuthLoadError.decodeFailed
        }
        let refresh = oauth["refreshToken"] as? String
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
            refreshToken: refresh,
            rateLimitTier: tier,
            subscriptionType: sub,
            expiresAt: expires
        )
    }

    static func saveCredentials(_ credentials: OAuthCredentials) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw OAuthLoadError.notFound
        }

        var oauth = obj["claudeAiOauth"] as? [String: Any] ?? [:]
        oauth["accessToken"] = credentials.accessToken
        if let refreshToken = credentials.refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        if let expiresAt = credentials.expiresAt {
            oauth["expiresAt"] = Int64(expiresAt.timeIntervalSince1970 * 1000)
        }
        if let rateLimitTier = credentials.rateLimitTier {
            oauth["rateLimitTier"] = rateLimitTier
        }
        if let subscriptionType = credentials.subscriptionType {
            oauth["subscriptionType"] = subscriptionType
        }
        obj["claudeAiOauth"] = oauth

        guard let updatedData = try? JSONSerialization.data(withJSONObject: obj) else {
            throw OAuthLoadError.decodeFailed
        }
        let update: [String: Any] = [kSecValueData as String: updatedData]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw OAuthLoadError.notFound
        }
    }
}

extension OAuthCredentials {
    func isUsable(now: Date = Date(), expiryLeeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(now) > expiryLeeway
    }
}

actor ClaudeCredentialCache {
    static let shared = ClaudeCredentialCache()

    private var cached: (credentials: OAuthCredentials, loadedAt: Date)?

    func credentials(
        now: Date = Date(),
        allowUserInteraction: Bool,
        loader: (_ allowUserInteraction: Bool) throws -> OAuthCredentials
    ) throws -> OAuthCredentials {
        if let cached {
            let usable = cached.credentials.isUsable(now: now)
            let cacheAge = now.timeIntervalSince(cached.loadedAt)
            if usable && cacheAge < claudeCredentialCacheMaxAge {
                return cached.credentials
            }

            do {
                let fresh = try loader(allowUserInteraction)
                self.cached = (fresh, now)
                return fresh
            } catch {
                if usable {
                    return cached.credentials
                }
                throw error
            }
        }
        let fresh = try loader(allowUserInteraction)
        cached = (fresh, now)
        return fresh
    }

    func invalidate() {
        cached = nil
    }

    func store(_ credentials: OAuthCredentials) {
        cached = (credentials, Date())
    }
}
