import Foundation
import Security

/// The user's own API keys, one per service. Written and read by the app
/// itself, so macOS does not prompt for keychain access the way it does for an
/// item created by an outside tool.
enum Keychain {
    private static let service = "dev.typeswitch.app"
    /// Up to 1.0.4 one key served every address, under this account. Kept only
    /// so that key can be handed to a service (`adoptSharedKey`).
    private static let sharedAccount = "provider-api-key"

    /// The item holding the key for the service at this address. One key for
    /// all of them sent a key meant for one service to the next one picked.
    /// Every address that is not a known service shares the custom item. An
    /// empty address is the default service's, as it is to `Prefs.baseURL` and
    /// so to the request.
    static func account(forBaseURL baseURL: String) -> String {
        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? KnownEndpoint.default.baseURL : baseURL
        return "\(sharedAccount).\(KnownEndpoint.matching(address)?.id ?? "custom")"
    }

    /// Whether a key is stored for this address, without reading it.
    ///
    /// Asking only for a match and not for the data is what keeps this quiet:
    /// the keychain's access prompt guards the secret itself, so a query that
    /// returns none never raises one.
    static func hasAPIKey(forBaseURL baseURL: String) -> Bool {
        var query = item(account(forBaseURL: baseURL))
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func apiKey(forBaseURL baseURL: String) -> String? {
        read(account(forBaseURL: baseURL))
    }

    static func setAPIKey(_ value: String?, forBaseURL baseURL: String) {
        let account = account(forBaseURL: baseURL)
        if let value, !value.isEmpty { write(value, to: account) } else { delete(account) }
    }

    /// The shared key was entered for the service selected at the time, which
    /// is still the selected one the first time this version launches. Renamed
    /// rather than copied, so the secret is never read to move it; a service
    /// that already has its own key keeps it.
    static func adoptSharedKey(forBaseURL baseURL: String) {
        let status = SecItemUpdate(
            item(sharedAccount) as CFDictionary,
            [kSecAttrAccount as String: account(forBaseURL: baseURL)] as CFDictionary
        )
        if status == errSecDuplicateItem { delete(sharedAccount) }
    }

    private static func item(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func read(_ account: String) -> String? {
        var query = item(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ value: String, to account: String) {
        let query = item(account)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: Data(value.utf8)] as CFDictionary
        )
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    private static func delete(_ account: String) {
        SecItemDelete(item(account) as CFDictionary)
    }
}
