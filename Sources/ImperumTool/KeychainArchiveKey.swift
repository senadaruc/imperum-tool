// Sources/ImperumTool/KeychainArchiveKey.swift
import CryptoKit
import Foundation
import Security
import ImperumCore

/// 256-bit archive key in the login Keychain. Generated on first use; `rotate()`
/// replaces it (the caller must discard the old archive first).
final class KeychainArchiveKey: ArchiveKeyProvider {
    enum KeychainError: Error { case status(OSStatus), malformedItem }
    private let service: String
    private let account: String
    private var cached: SymmetricKey?

    init(service: String = "io.imperum.tool.clipboard", account: String = "archive-key") {
        self.service = service; self.account = account
    }

    func key() throws -> SymmetricKey {
        if let k = cached { return k }
        if let data = try read() { let k = SymmetricKey(data: data); cached = k; return k }
        return try rotate()
    }

    @discardableResult
    func rotate() throws -> SymmetricKey {
        let k = SymmetricKey(size: .bits256)
        let data = k.withUnsafeBytes { Data($0) }
        SecItemDelete(baseQuery() as CFDictionary)
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let st = SecItemAdd(add as CFDictionary, nil)
        guard st == errSecSuccess else { throw KeychainError.status(st) }
        cached = k
        return k
    }

    private func read() throws -> Data? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess else { throw KeychainError.status(st) }
        guard let data = out as? Data else { throw KeychainError.malformedItem }
        guard data.count == 32 else { throw KeychainError.malformedItem }
        return data
    }

    private func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
