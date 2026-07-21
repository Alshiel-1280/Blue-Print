import Foundation
import Security

enum BackupCredentialError: Error {
  case keychain(OSStatus)
}

struct BackupCredentialStore {
  private let service = "io.github.alshiel1280.blueprint.automatic-backup"
  private let account = "local-mac-user"

  func save(_ passphrase: String) throws {
    let data = Data(passphrase.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var item = query
      for (key, value) in attributes { item[key] = value }
      let addStatus = SecItemAdd(item as CFDictionary, nil)
      guard addStatus == errSecSuccess else { throw BackupCredentialError.keychain(addStatus) }
    } else if status != errSecSuccess {
      throw BackupCredentialError.keychain(status)
    }
  }

  func load() throws -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else {
      throw BackupCredentialError.keychain(status)
    }
    return String(data: data, encoding: .utf8)
  }

  func remove() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw BackupCredentialError.keychain(status)
    }
  }
}
