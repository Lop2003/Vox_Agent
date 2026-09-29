import Foundation
import Security

/// The pairing code lets whoever holds it run agents on the Mac, so it lives in the Keychain.
enum PairingStore {
    private static let service = "com.voxcode.pairing"

    static var code: String? {
        get {
            var item: CFTypeRef?
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecReturnData as String: true]
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            SecItemDelete(query as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = query
            add[kSecValueData as String] = Data(newValue.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Optional explicit address (e.g. a Tailscale IP) when Bonjour can't see the Mac.
    static var host: String {
        get { UserDefaults.standard.string(forKey: "bridgeHost") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "bridgeHost") }
    }
}
