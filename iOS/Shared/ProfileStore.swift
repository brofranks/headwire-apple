import Foundation
import NetworkExtension
import Security

/// On iOS, a profile's configuration text is a keychain item shared by the app
/// and the provider through the app group. The NetworkExtension configuration
/// holds only a persistent reference to it.
enum ProfileStore {
    struct Failure: LocalizedError {
        var status: OSStatus
        var errorDescription: String? {
            "keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")"
        }
    }

    private static let service = Identifiers.product
    private static let group = Bundle.main.object(forInfoDictionaryKey: "HeadwireAppGroup") as! String

    static func add(_ name: String, text: String) throws -> Data {
        var ref: CFTypeRef?
        let status = SecItemAdd(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: name,
                kSecAttrAccessGroup: group,
                // The provider may be started while the device is locked.
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
                kSecValueData: Data(text.utf8),
                kSecReturnPersistentRef: true,
            ] as CFDictionary, &ref)
        guard status == errSecSuccess, let ref = ref as? Data else {
            throw Failure(status: status)
        }
        return ref
    }

    /// nil means the item is gone. Any other failure, such as a keychain that
    /// is still locked, throws: callers delete what no longer resolves.
    static func read(_ ref: Data?) throws -> String? {
        guard let ref else { return nil }
        var data: CFTypeRef?
        let status = SecItemCopyMatching([kSecValuePersistentRef: ref, kSecReturnData: true] as CFDictionary, &data)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = data as? Data else { throw Failure(status: errSecDecode) }
        return String(decoding: data, as: UTF8.self)
    }

    static func delete(_ ref: Data) throws {
        let status = SecItemDelete([kSecValuePersistentRef: ref] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    /// The persistent reference of every stored item, for the repository to
    /// delete those no configuration refers to any more.
    static func references() throws -> Set<Data> {
        var all: CFTypeRef?
        let status = SecItemCopyMatching(
            [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccessGroup: group,
                kSecMatchLimit: kSecMatchLimitAll,
                kSecReturnPersistentRef: true,
            ] as CFDictionary, &all)
        guard status != errSecItemNotFound else { return [] }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let references = all as? [Data] else { throw Failure(status: errSecDecode) }
        return Set(references)
    }
}
