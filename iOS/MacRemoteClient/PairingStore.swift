import Foundation
import Security
import Darwin

enum PairingStore {
    private static let service = "MacRemotePSK"
    struct Credentials: Codable {
        let transportSecret: Data
        let deviceCredential: Data
        var enrollmentToken: Data?
        var macName: String?
        // Supplied by newer pairing QR codes. It bypasses multicast Bonjour on
        // networks that permit direct device traffic but suppress discovery.
        var directHost: String?
        var directHostV6: String?
        var directPort: UInt16?
    }
    private static var sharedAccessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "MacRemoteKeychainAccessGroup") as? String
    }

    static func load() -> Credentials? {
        if let group = sharedAccessGroup, let data = read(accessGroup: group) { return decodeStored(data) }
        // Existing installations stored the credential in the app-only keychain.
        // Migrate it on first launch so extensions can use it afterwards.
        guard let legacy = read(accessGroup: nil), let credentials = decodeStored(legacy) else { return nil }
        save(credentials)
        return credentials
    }

    static func save(_ credentials: Credentials) {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        var base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        if let group = sharedAccessGroup { base[kSecAttrAccessGroup] = group }
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        var item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service]
        if let group = sharedAccessGroup {
            item[kSecAttrAccessGroup] = group
            SecItemDelete(item as CFDictionary)
            item.removeValue(forKey: kSecAttrAccessGroup)
        }
        SecItemDelete(item as CFDictionary)
    }

    private static func read(accessGroup: String?) -> Data? {
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecReturnData: true]
        if let accessGroup { query[kSecAttrAccessGroup] = accessGroup }
        var output: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &output) == errSecSuccess ? output as? Data : nil
    }

    static func decode(_ input: String) -> Credentials? {
        let prefix = "macremote://pair/v1/"
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(prefix) else { return nil }
        var base64 = String(text.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let enrollment = try? JSONDecoder().decode(Enrollment.self, from: data),
              enrollment.version == 1,
              let secret = Data(base64Encoded: enrollment.secret), secret.count == 32,
              let token = Data(base64Encoded: enrollment.token), token.count == 32 else { return nil }
        var credential = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, credential.count, &credential) == errSecSuccess else { return nil }
        let host = enrollment.directHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        let directHost = host.flatMap { !$0.isEmpty && $0.count <= 253 ? $0 : nil }
        let hostV6 = enrollment.directHostV6?.trimmingCharacters(in: .whitespacesAndNewlines)
        let directHostV6 = hostV6.flatMap { !$0.isEmpty && $0.count <= 253 ? $0 : nil }
        let directPort = enrollment.directPort.flatMap { $0 == 0 ? nil : $0 }
        return Credentials(transportSecret: secret, deviceCredential: Data(credential), enrollmentToken: token,
                           macName: nil, directHost: directHost, directHostV6: directHostV6, directPort: directPort)
    }

    private struct Enrollment: Codable {
        let version: Int
        let secret: String
        let token: String
        let directHost: String?
        let directHostV6: String?
        let directPort: UInt16?
    }
    private static func decodeStored(_ data: Data) -> Credentials? {
        guard let credentials = try? JSONDecoder().decode(Credentials.self, from: data),
              credentials.transportSecret.count == 32, credentials.deviceCredential.count == 32,
              credentials.enrollmentToken == nil || credentials.enrollmentToken?.count == 32 else { return nil }
        return credentials
    }
}

enum LocalNetworkIdentity {
    static var hasActiveWiFi: Bool {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return false }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor {
            defer { cursor = interface.pointee.ifa_next }
            let flags = interface.pointee.ifa_flags
            guard String(cString: interface.pointee.ifa_name) == "en0",
                  flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_RUNNING) != 0 else { continue }
            return true
        }
        return false
    }

}
