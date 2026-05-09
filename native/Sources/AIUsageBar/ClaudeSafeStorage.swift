import CommonCrypto
import Foundation
import LocalAuthentication
import Security

enum ClaudeSafeStorageReader {
    private static let safeStorageService = "Claude Safe Storage"
    private static let safeStorageAccounts = ["Claude", "Claude Key"]
    private static let tokenCacheKey = "oauth:tokenCache"

    static func loadCredentials(allowUserInteraction: Bool = true) throws -> OAuthCredentials {
        let password = try loadSafeStoragePassword(allowUserInteraction: allowUserInteraction)
        let encrypted = try loadEncryptedTokenCache()
        let decrypted = try decryptTokenCache(encrypted, password: password)
        return try credentials(fromDecryptedTokenCache: decrypted)
    }

    static func credentials(
        fromDecryptedTokenCache data: Data,
        now: Date = Date()
    ) throws -> OAuthCredentials {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthLoadError.decodeFailed
        }

        let candidates = obj.compactMap { key, raw -> (key: String, credentials: OAuthCredentials)? in
            guard let entry = raw as? [String: Any],
                  let token = entry["token"] as? String,
                  !token.isEmpty
            else { return nil }

            let credentials = OAuthCredentials(
                accessToken: token,
                refreshToken: entry["refreshToken"] as? String,
                rateLimitTier: entry["rateLimitTier"] as? String,
                subscriptionType: entry["subscriptionType"] as? String,
                expiresAt: dateFromMilliseconds(entry["expiresAt"])
            )
            return (key, credentials)
        }

        guard !candidates.isEmpty else {
            throw OAuthLoadError.decodeFailed
        }

        return candidates.sorted { lhs, rhs in
            let leftUsable = lhs.credentials.isUsable(now: now)
            let rightUsable = rhs.credentials.isUsable(now: now)
            if leftUsable != rightUsable { return leftUsable }

            let leftExpiry = lhs.credentials.expiresAt ?? .distantFuture
            let rightExpiry = rhs.credentials.expiresAt ?? .distantFuture
            if leftExpiry != rightExpiry { return leftExpiry > rightExpiry }

            let leftIsClaudeCode = lhs.key.contains("user:sessions:claude_code")
            let rightIsClaudeCode = rhs.key.contains("user:sessions:claude_code")
            if leftIsClaudeCode != rightIsClaudeCode { return leftIsClaudeCode }
            return lhs.key < rhs.key
        }[0].credentials
    }

    private static func loadSafeStoragePassword(allowUserInteraction: Bool) throws -> Data {
        var lastStatus: OSStatus = errSecItemNotFound
        for account in safeStorageAccounts {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: safeStorageService,
                kSecAttrAccount as String: account,
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
            if status == errSecSuccess, let data = item as? Data {
                return data
            }
            if status == errSecInteractionNotAllowed
                || status == errSecAuthFailed
                || status == errSecUserCanceled {
                throw OAuthLoadError.interactionNotAllowed
            }
            lastStatus = status
        }

        if lastStatus == errSecItemNotFound {
            throw OAuthLoadError.notFound
        }
        throw OAuthLoadError.decodeFailed
    }

    private static func loadEncryptedTokenCache() throws -> String {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/config.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let encrypted = obj[tokenCacheKey] as? String,
              !encrypted.isEmpty
        else {
            throw OAuthLoadError.notFound
        }
        return encrypted
    }

    private static func decryptTokenCache(
        _ encryptedBase64: String,
        password: Data
    ) throws -> Data {
        guard let encrypted = Data(base64Encoded: encryptedBase64),
              encrypted.count > 3,
              encrypted.prefix(3) == Data("v10".utf8)
        else {
            throw OAuthLoadError.decodeFailed
        }

        let salt = Array("saltysalt".utf8)
        let passBytes = password.map { CChar(bitPattern: $0) }
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derivation = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passBytes,
            passBytes.count,
            salt,
            salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1003,
            &key,
            key.count
        )
        guard derivation == kCCSuccess else {
            throw OAuthLoadError.decodeFailed
        }

        let cipher = [UInt8](encrypted.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var outLength = 0
        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            key,
            key.count,
            iv,
            cipher,
            cipher.count,
            &out,
            out.count,
            &outLength
        )
        guard status == kCCSuccess else {
            throw OAuthLoadError.decodeFailed
        }
        return Data(out.prefix(outLength))
    }

    private static func dateFromMilliseconds(_ value: Any?) -> Date? {
        if let ms = value as? Double {
            return Date(timeIntervalSince1970: ms / 1000)
        }
        if let ms = value as? Int64 {
            return Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        if let ms = value as? Int {
            return Date(timeIntervalSince1970: Double(ms) / 1000)
        }
        if let ms = value as? NSNumber {
            return Date(timeIntervalSince1970: ms.doubleValue / 1000)
        }
        return nil
    }
}

enum ClaudeCredentialReader {
    static func loadCredentials(allowUserInteraction: Bool = true) throws -> OAuthCredentials {
        do {
            return try ClaudeSafeStorageReader.loadCredentials(
                allowUserInteraction: allowUserInteraction
            )
        } catch OAuthLoadError.interactionNotAllowed {
            throw OAuthLoadError.interactionNotAllowed
        } catch {
            return try KeychainReader.loadCredentials(
                allowUserInteraction: allowUserInteraction
            )
        }
    }
}
