import DynamicSecrets
import Foundation
import RuntimeSecrets
import Security

/// `HostSecrets`' store: generic passwords in the Keychain, with the app's
/// identifier as the service and the key as the account.
///
/// - **This device only:** `…ThisDeviceOnly` accessibility, so a secret
///   isn't in a backup or synced to the user's other devices.
/// - **Gone with the app:** Keychain items outlive an app on iOS, so a
///   marker in the host's own folder says whether this is the first run
///   since the app was installed, and the store is emptied then.
/// - **macOS:** the data protection keychain, as iOS has, where the app is
///   signed for it; otherwise the login keychain, where accessibility
///   doesn't apply.
///
/// Called off the main thread, one call at a time. Nothing is logged.
final class KeychainStore: SecretStore, @unchecked Sendable {

    let service: String

    /// Says the store has been emptied since the app was installed.
    let marker: String?

    private var prepared = false

    #if os(macOS)
    /// Whether the data protection keychain is there for this process,
    /// found on first use.
    private var dataProtection: Bool?
    #endif

    init(service: String, marker: String?) {
        self.service = service
        self.marker = marker
    }

    // MARK: Queries

    private var base: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        #if os(macOS)
        if dataProtection == true {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        #endif
        return query
    }

    private func query(_ key: String) -> [String: Any] {
        var query = base
        query[kSecAttrAccount as String] = key
        return query
    }

    static func accessible(_ accessibility: KeychainAccessibility) -> CFString {
        switch accessibility {
        case .whenUnlocked: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .afterFirstUnlock: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }

    /// What the guest is told of a failure. A locked device is
    /// `unavailable`; the user refusing is `notAllowed`.
    static func error(_ status: OSStatus) -> KeychainError {
        switch status {
        case errSecUserCanceled, errSecAuthFailed:
            return .notAllowed
        default:
            return .unavailable
        }
    }

    // MARK: Before the first call

    /// Finds the keychain to use, and empties the store on the first run
    /// since the app was installed.
    private func prepare() throws(KeychainError) {
        guard !prepared else { return }
        #if os(macOS)
        if dataProtection == nil {
            dataProtection = Self.hasDataProtection()
        }
        #endif
        if let marker, !FileManager.default.fileExists(atPath: marker) {
            try deleteAll()
            FileManager.default.createFile(atPath: marker, contents: nil)
        }
        prepared = true
    }

    #if os(macOS)
    /// Whether this process may use the data protection keychain. A search
    /// says "not found" either way; deleting an item that isn't there is
    /// refused for want of an entitlement, when that's missing.
    private static func hasDataProtection() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.pureswift.runtime.secrets.probe",
            kSecAttrAccount as String: UUID().uuidString,
            kSecUseDataProtectionKeychain as String: true,
        ]
        return SecItemDelete(query as CFDictionary) != errSecMissingEntitlement
    }
    #endif

    // MARK: The store

    func set(_ key: String, value: [UInt8], accessibility: KeychainAccessibility) throws(KeychainError) {
        try prepare()
        var attributes: [String: Any] = [kSecValueData as String: Data(value)]
        #if os(macOS)
        if dataProtection == true {
            attributes[kSecAttrAccessible as String] = Self.accessible(accessibility)
        }
        #else
        attributes[kSecAttrAccessible as String] = Self.accessible(accessibility)
        #endif
        // Replaced whole, so the accessibility is the new one too.
        let deleted = SecItemDelete(query(key) as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            throw Self.error(deleted)
        }
        let item = query(key).merging(attributes) { $1 }
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw Self.error(added)
        }
    }

    func value(forKey key: String) throws(KeychainError) -> [UInt8]? {
        try prepare()
        var search = query(key)
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).map(Array.init) ?? []
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(status)
        }
    }

    func remove(_ key: String) throws(KeychainError) {
        try prepare()
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(status)
        }
    }

    func removeAll() throws(KeychainError) {
        try prepare()
        try deleteAll()
    }

    /// Every item of the service. The login keychain deletes one at a time.
    private func deleteAll() throws(KeychainError) {
        for _ in 0 ..< 10_000 {
            let status = SecItemDelete(base as CFDictionary)
            if status == errSecItemNotFound {
                return
            }
            guard status == errSecSuccess else {
                throw Self.error(status)
            }
        }
    }

    func keys() throws(KeychainError) -> [String] {
        try prepare()
        var search = base
        search[kSecReturnAttributes as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(search as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = result as? [[String: Any]] ?? []
            return items.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw Self.error(status)
        }
    }
}
