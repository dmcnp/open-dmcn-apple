import Foundation
import LocalAuthentication
import Security

/// Accounts' secrets in the Keychain, this device only, never in a backup or iCloud. The list of
/// accounts itself holds nothing secret, so it sits in user defaults, where reading it needs no
/// prompt: the picker can show who's here before anyone unlocks.
struct KeychainVault: AccountVault {
    private static let service = "org.dmcn.app.keys"
    private static let indexKey = "accounts"

    func accounts() async -> [DeviceAccount] {
        guard let data = UserDefaults.standard.data(forKey: Self.indexKey) else { return [] }
        return (try? JSONDecoder().decode([DeviceAccount].self, from: data)) ?? []
    }

    func save(_ account: DeviceAccount, secret: Data) async throws {
        var query = Self.query(account.address)
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = secret
        switch account.protection {
        case .device:
            // A key that needs presence every time, and is gone if the passcode is ever removed.
            var error: Unmanaged<CFError>?
            guard
                let access = SecAccessControlCreateWithFlags(
                    nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error)
            else { throw KeychainError(status: errSecParam) }
            query[kSecAttrAccessControl as String] = access
        case .passphrase:
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        var all = await accounts().filter { $0.address != account.address }
        all.append(account)
        UserDefaults.standard.set(try JSONEncoder().encode(all), forKey: Self.indexKey)
    }

    func read(_ account: DeviceAccount) async throws -> Data {
        // Off the main actor: this call blocks for as long as the system prompt is up.
        try await Task.detached {
            var query = Self.query(account.address)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let context = LAContext()
            context.localizedReason = "Unlock \(account.address)"
            query[kSecUseAuthenticationContext as String] = context
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
            return data
        }.value
    }

    func remove(_ account: DeviceAccount) async {
        SecItemDelete(Self.query(account.address) as CFDictionary)
        let all = await accounts().filter { $0.address != account.address }
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: Self.indexKey)
    }

    private static func query(_ address: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: address,
        ]
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        switch status {
        case errSecUserCanceled, errSecAuthFailed: "Unlocking was cancelled."
        case errSecItemNotFound: VaultError.missing.errorDescription
        default: "This device couldn't reach its keychain (\(status))."
        }
    }
}

extension KeyProtection {
    /// Whether this device can ask for a biometric or its passcode at all.
    static var deviceAuthAvailable: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// What the choice is called on this device.
    static var deviceAuthName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Device passcode"
        }
    }

    static var preferred: KeyProtection { deviceAuthAvailable ? .device : .passphrase }
}
