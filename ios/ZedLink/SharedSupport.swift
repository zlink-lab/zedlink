import Foundation
import Security

// Compiled into both the app and the ZLinkShare extension (see project-share.yml). Foundation and
// Security only. The App Group exists only in builds signed with the share-extension profiles; in
// the default build every shared path below degrades to the app's own storage.

enum AppGroup {
    static let identifier = "group.cx.m42.zlink"

    /// The shared container, or nil when this build has no App Group entitlement.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var isAvailable: Bool { containerURL != nil }

    /// Shared defaults, only when the entitlement is present (a suite without it is app-private).
    static var defaults: UserDefaults? {
        isAvailable ? UserDefaults(suiteName: identifier) : nil
    }
}

actor CredentialVault {
    static let shared = CredentialVault()
    private let service = "dev.zedlink.gateway"

    /// App Group ids double as keychain access groups, so the extension can read the credential
    /// without a separate keychain-sharing entitlement. Nil in builds without the App Group.
    private var sharedAccessGroup: String? { AppGroup.isAvailable ? AppGroup.identifier : nil }

    private func read(account: String, accessGroup: String? = nil) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func gatewayAccount(_ gatewayID: String) -> String {
        "gateway:\(gatewayID.lowercased())"
    }

    /// Credentials follow the gateway identity, rather than a route or profile UUID.
    /// The UUID fallback migrates credentials written by ZedLink 1.x in place.
    func read(_ profile: ConnectionProfile) -> String? {
        let account = gatewayAccount(profile.gatewayID)
        if let token = read(account: account) {
            // Move an app-private credential into the shared group once it exists.
            if let group = sharedAccessGroup, read(account: account, accessGroup: group) == nil {
                try? write(token, for: profile)
            }
            return token
        }
        guard let legacy = read(account: profile.id.uuidString) else { return nil }
        do {
            try write(legacy, for: profile)
            delete(account: profile.id.uuidString)
        } catch { /* Keep the legacy entry if migration cannot be committed. */ }
        return legacy
    }

    func write(_ token: String, for profile: ConnectionProfile) throws {
        let account = gatewayAccount(profile.gatewayID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let group = sharedAccessGroup {
            add[kSecAttrAccessGroup as String] = group
            if SecItemAdd(add as CFDictionary, nil) == errSecSuccess { return }
            add.removeValue(forKey: kSecAttrAccessGroup as String)
        }
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw GatewayFailure.native("Could not save the device credential in Keychain.")
        }
    }

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    func delete(_ profile: ConnectionProfile) {
        delete(account: gatewayAccount(profile.gatewayID))
        delete(account: profile.id.uuidString)
    }
}

/// Saved connection profiles mirrored into the App Group for the share extension.
enum SharedProfiles {
    static let key = "zedlink.profiles.v1"
    static let lastProfileKey = "zedlink.last-profile.v1"

    static func publish(_ profiles: [ConnectionProfile], lastUsed: String?) {
        guard let defaults = AppGroup.defaults, let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: key)
        if let lastUsed { defaults.set(lastUsed, forKey: lastProfileKey) } else { defaults.removeObject(forKey: lastProfileKey) }
    }

    static func load() -> (profiles: [ConnectionProfile], lastUsed: UUID?) {
        guard let defaults = AppGroup.defaults, let data = defaults.data(forKey: key),
              let profiles = try? JSONDecoder().decode([ConnectionProfile].self, from: data) else { return ([], nil) }
        return (profiles, defaults.string(forKey: lastProfileKey).flatMap(UUID.init(uuidString:)))
    }
}

/// A share the extension hands to the app because its files are too large to upload from the
/// extension's short lifetime. Stored as `Inbox/<id>/manifest.json` plus the files in the App Group.
struct SharedInboxItem: Codable, Identifiable {
    struct File: Codable {
        let fileName: String
        let mimeType: String
        /// Name of the copy inside the item's folder.
        let storedName: String
    }
    var id = UUID()
    let gatewayID: String
    let targetID: String
    let threadID: String
    let threadTitle: String
    let text: String
    let files: [File]
    var created = Date()
}

enum SharedInbox {
    static var directory: URL? {
        AppGroup.containerURL?.appendingPathComponent("Inbox", isDirectory: true)
    }

    static func folder(for id: UUID) -> URL? {
        directory?.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func items() -> [SharedInboxItem] {
        guard let directory,
              let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder -> SharedInboxItem? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")) else { return nil }
            return try? JSONDecoder().decode(SharedInboxItem.self, from: data)
        }.sorted { $0.created < $1.created }
    }

    /// Writes the manifest last, so the app never sees a half-copied item.
    static func save(_ item: SharedInboxItem, files: [(storedName: String, data: Data)]) throws {
        guard let folder = folder(for: item.id) else { throw GatewayFailure.native("The shared App Group is unavailable in this build.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files { try file.data.write(to: folder.appendingPathComponent(file.storedName), options: .atomic) }
        try JSONEncoder().encode(item).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }

    /// Like `save`, copying files that are already on disk (no full read into the extension's memory).
    static func save(_ item: SharedInboxItem, copying files: [(storedName: String, url: URL)]) throws {
        guard let folder = folder(for: item.id) else { throw GatewayFailure.native("The shared App Group is unavailable in this build.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            let destination: URL = folder.appendingPathComponent(file.storedName)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: file.url, to: destination)
        }
        try JSONEncoder().encode(item).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }

    static func data(_ file: SharedInboxItem.File, of item: SharedInboxItem) -> Data? {
        guard let folder = folder(for: item.id) else { return nil }
        return try? Data(contentsOf: folder.appendingPathComponent(file.storedName))
    }

    static func remove(_ item: SharedInboxItem) {
        guard let folder = folder(for: item.id) else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}
