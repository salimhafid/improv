import Foundation
import Security

/// Minimal Keychain wrapper — the app's first secure storage. Holds the UCB
/// session validity marker (and any small session metadata) on-device only.
///
/// Accessibility is `AfterFirstUnlockThisDeviceOnly`: readable in the
/// background after the first unlock (so a geofence wake can check sign-in
/// state), never synced to iCloud Keychain — a third-party session stays on
/// this device, which is also what App Review expects.
enum Keychain {
    private static let service = "com.salimhafid.UCBShows.ucb"

    @discardableResult
    static func set(_ data: Data, for key: String) -> Bool {
        // Delete any existing item first so this is an upsert.
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func data(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: String convenience

    static func set(_ string: String, for key: String) {
        set(Data(string.utf8), for: key)
    }

    static func string(for key: String) -> String? {
        data(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }
}
