import Foundation
import Security

/// Embedding <-> BLOB + cosine.
enum VectorStore {
    static func encode(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    static func decode(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i]*b[i]; na += a[i]*a[i]; nb += b[i]*b[i] }
        let den = na.squareRoot() * nb.squareRoot()
        return den == 0 ? 0 : dot / den
    }
}

/// Görsel/video/pdf dosyaları — App Group container (app + extension ortak).
enum AssetStore {
    private static var dir: URL {
        let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: DatabaseManager.appGroupID)!
            .appendingPathComponent("assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    static func save(_ data: Data, ext: String) -> String {
        let name = "\(UUID().uuidString).\(ext)"
        try? data.write(to: dir.appendingPathComponent(name))
        return name
    }
    static func copy(fileURL: URL, ext: String) -> String {
        let name = "\(UUID().uuidString).\(ext)"
        try? FileManager.default.copyItem(at: fileURL, to: dir.appendingPathComponent(name))
        return name
    }
    static func url(for relative: String) -> URL { dir.appendingPathComponent(relative) }
}

/// SQLCipher passphrase — Keychain'de, app+extension ortak (Keychain Sharing capability şart).
enum KeychainKey {
    private static let service = "app.zihin.db"
    private static let account = "passphrase"

    static func databasePassphrase() throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true]
        var out: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
           let data = out as? Data, let pass = String(data: data, encoding: .utf8) {
            return pass
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let pass = Data(bytes).base64EncodedString()
        query.removeValue(forKey: kSecReturnData as String)
        query[kSecValueData as String] = Data(pass.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
        return pass
    }
}
