import Foundation
import Combine

@MainActor final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [ConnectionProfile] = []
    private let key = "zedlink.profiles.v1"
    private let lastProfileKey = "zedlink.last-profile.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let profiles = try? JSONDecoder().decode([ConnectionProfile].self, from: data) {
            self.profiles = Self.migratedRoutes(profiles)
        }
        publishShared()
    }

    /// Profiles saved before route detection existed defaulted to Tailscale, even for LAN addresses.
    nonisolated static func migratedRoutes(_ profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        profiles.map { profile in
            guard profile.route == .tailscale, let detected = RouteKind.detect(endpoint: profile.endpoint),
                  detected != .tailscale else { return profile }
            var fixed = profile
            fixed.route = detected
            return fixed
        }
    }

    private func publishShared() {
        SharedProfiles.publish(profiles, lastUsed: UserDefaults.standard.string(forKey: lastProfileKey))
    }

    @discardableResult
    func save(_ profile: ConnectionProfile) -> ConnectionProfile {
        let saved = Self.profileForSave(profile, among: profiles)
        profiles.removeAll { $0.id == saved.id }
        profiles.append(saved)
        persist()
        return saved
    }

    static func profileForSave(_ profile: ConnectionProfile, among profiles: [ConnectionProfile]) -> ConnectionProfile {
        guard let existing = profiles.first(where: {
            $0.id == profile.id ||
                ($0.gatewayID.caseInsensitiveCompare(profile.gatewayID) == .orderedSame &&
                 normalizedEndpoint($0.endpoint) == normalizedEndpoint(profile.endpoint))
        }) else { return profile }
        var saved = profile
        saved.id = existing.id
        return saved
    }

    private static func normalizedEndpoint(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    /// Stores which configured address (main or mesh) passed the identity check last, so the next
    /// launch tries it first. Ignores addresses the profile no longer has.
    func recordWorkingEndpoint(profileID: UUID, endpoint: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }),
              profiles[index].endpoints.contains(endpoint),
              profiles[index].lastWorkingEndpoint != endpoint else { return }
        profiles[index].lastWorkingEndpoint = endpoint
        persist()
    }

    var preferredProfile: ConnectionProfile? {
        if let value = UserDefaults.standard.string(forKey: lastProfileKey),
           let id = UUID(uuidString: value),
           let profile = profiles.first(where: { $0.id == id }) { return profile }
        return profiles.first
    }

    func markUsed(_ profile: ConnectionProfile) {
        UserDefaults.standard.set(profile.id.uuidString, forKey: lastProfileKey)
        publishShared()
    }

    func remove(_ profile: ConnectionProfile) async {
        profiles.removeAll { $0.id == profile.id }
        if UserDefaults.standard.string(forKey: lastProfileKey) == profile.id.uuidString {
            UserDefaults.standard.removeObject(forKey: lastProfileKey)
        }
        persist()
        let stillUsesCredential = profiles.contains {
            $0.gatewayID.caseInsensitiveCompare(profile.gatewayID) == .orderedSame
        }
        if !stillUsesCredential {
            await CredentialVault.shared.delete(profile)
            await ConversationCache.shared.remove(gatewayID: profile.gatewayID)
            ComposerLibrary.shared.forgetGateway(profile.gatewayID)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: key)
        }
        publishShared()
    }
}
