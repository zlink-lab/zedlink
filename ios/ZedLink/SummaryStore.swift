import Foundation
import Combine

/// One thread in the Summary tab: which connection, Zed target, host and workspace it lives in,
/// and its last known state. Persisted so the tab still reads when a gateway is offline.
/// Only routing metadata and titles are stored, never transcript text.
struct SummaryEntry: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case running, waiting, done, error

        var label: String {
            switch self {
            case .running: "Running"
            case .waiting: "Waiting for you"
            case .done: "Done"
            case .error: "Error"
            }
        }

        var symbol: String {
            switch self {
            case .running: "waveform"
            case .waiting: "hand.raised"
            case .done: "checkmark.circle"
            case .error: "exclamationmark.triangle"
            }
        }
    }

    let gatewayID: String
    var connectionName: String
    let targetID: String
    var hostID: String?
    var hostLabel: String?
    var projectID: String?
    var workspaceLabel: String?
    let threadID: String
    var title: String
    var agent: String?
    var status: Status
    var updatedAt: Date

    var id: String { [gatewayID.lowercased(), targetID, threadID].joined(separator: "\n") }

    var place: String {
        [connectionName, hostLabel, workspaceLabel].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var searchText: String {
        [title, connectionName, hostLabel ?? "", workspaceLabel ?? "", agent ?? "", status.label].joined(separator: " ")
    }

    static func status(of thread: NativeThread) -> Status {
        let activity = SessionActivity(thread)
        if activity == .approval || activity == .input { return .waiting }
        if activity == .failed { return .error }
        if activity.running { return .running }
        return .done
    }

    /// From a raw `thread.list` row.
    static func status(row: [String: Any]) -> Status {
        let status: String = row["status"] as? String ?? "Unknown"
        let turn: Int? = row["current_turn_id"] as? Int
        let activity = NativeAgentActivity(row["activity"], status: status, currentTurnID: turn)
        if activity.isWaitingForApproval || activity.phase == "waiting_for_input" { return .waiting }
        if activity.isWorking || status == "Generating" { return .running }
        if row["had_error"] as? Bool == true || row["agent_error"] is [String: Any] { return .error }
        return .done
    }
}

/// Threads across every saved connection, Zed target, host and workspace, newest first.
@MainActor final class SummaryStore: ObservableObject {
    @Published private(set) var entries: [SummaryEntry] = []
    @Published private(set) var refreshing = false
    /// Connection name → why it could not be refreshed (its rows stay as last known).
    @Published private(set) var issues: [String: String] = [:]
    @Published private(set) var lastRefresh: Date?
    private let storageURL: URL?
    private let keepFor: TimeInterval = 60 * 24 * 60 * 60
    private let maxEntries = 500

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ZedLink", isDirectory: true).appendingPathComponent("summary-v1.json")
        if let storageURL = self.storageURL, let data = try? Data(contentsOf: storageURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([SummaryEntry].self, from: data)) ?? []
        }
    }

    /// Asks every saved gateway (one working route per gateway id) for its targets, threads and
    /// history. A gateway that fails keeps its last known rows.
    func refresh(profiles: [ConnectionProfile]) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; lastRefresh = Date() }
        var seen: Set<String> = []
        var nextIssues: [String: String] = [:]
        for profile in profiles {
            let gateway: String = profile.gatewayID.lowercased()
            guard !seen.contains(gateway) else { continue }
            let routes: [ConnectionProfile] = profiles.filter { $0.gatewayID.lowercased() == gateway }
            var lastError: String?
            var refreshed = false
            for route in routes {
                do {
                    try await refreshGateway(route)
                    refreshed = true
                    break
                } catch {
                    lastError = error.localizedDescription
                }
            }
            seen.insert(gateway)
            if !refreshed, let lastError { nextIssues[profile.name] = lastError }
        }
        // Rows of removed connections disappear.
        entries.removeAll { entry in !profiles.contains(where: { $0.gatewayID.lowercased() == entry.gatewayID.lowercased() }) }
        issues = nextIssues
        save()
    }

    private func refreshGateway(_ profile: ConnectionProfile) async throws {
        guard let token = await CredentialVault.shared.read(profile) else { throw GatewayFailure.native("Pair this device first.") }
        let registry = try await GatewayClient(profile: profile, token: token).rpc("instance.list")
        guard let rows = registry["targets"] as? [[String: Any]] else { throw GatewayFailure.invalidResponse }
        for row in rows {
            guard let targetID = row["target_id"] as? String, row["available"] as? Bool ?? false else { continue }
            let client = GatewayClient(profile: profile, token: token, targetID: targetID)
            let info = try await client.rpc("instance.info")
            guard let instance = info["instance_id"] as? String, let epoch = info["epoch"] as? String else { continue }
            let capabilities = Set(info["capabilities"] as? [String] ?? [])
            let list = try await client.rpc("thread.list")
            let threadRows: [[String: Any]] = list["threads"] as? [[String: Any]] ?? []
            var hosts: [WorkspaceHost] = []
            if capabilities.contains("workspace.list") {
                let result = try? await client.rpc("workspace.list", params: ["instance_id": instance, "epoch": epoch])
                hosts = (result?["hosts"] as? [[String: Any]] ?? []).compactMap { WorkspaceHost(row: $0) }
            }
            replace(gatewayID: profile.gatewayID, connectionName: profile.name, targetID: targetID,
                    rows: threadRows, hosts: hosts)
        }
    }

    private func replace(gatewayID: String, connectionName: String, targetID: String,
                         rows: [[String: Any]], hosts: [WorkspaceHost]) {
        let now = Date()
        let previous: [String: SummaryEntry] = Dictionary(
            entries.filter { $0.gatewayID.lowercased() == gatewayID.lowercased() && $0.targetID == targetID }.map { ($0.threadID, $0) },
            uniquingKeysWith: { first, _ in first })
        var fresh: [String: SummaryEntry] = [:]
        for history in RecentHistoryThread.recent(in: hosts) {
            guard let date = history.thread.updatedAt, now.timeIntervalSince(date) <= keepFor else { continue }
            fresh[history.id] = SummaryEntry(gatewayID: gatewayID, connectionName: connectionName, targetID: targetID,
                                             hostID: history.hostID, hostLabel: history.hostLabel,
                                             projectID: history.projectID, workspaceLabel: history.project,
                                             threadID: history.id, title: history.thread.title ?? "Untitled thread",
                                             agent: history.thread.agent,
                                             status: previous[history.id]?.status == .error ? .error : .done,
                                             updatedAt: date)
        }
        for row in rows {
            guard let threadID = row["thread_id"] as? String else { continue }
            let status: SummaryEntry.Status = SummaryEntry.status(row: row)
            var entry: SummaryEntry = fresh[threadID] ?? previous[threadID] ?? SummaryEntry(
                gatewayID: gatewayID, connectionName: connectionName, targetID: targetID, threadID: threadID,
                title: "Untitled Agent thread", status: status, updatedAt: now)
            entry.connectionName = connectionName
            if let title = row["title"] as? String, !title.isEmpty { entry.title = title }
            if let host = row["host_id"] as? String, !host.isEmpty { entry.hostID = host }
            if let project = row["project_id"] as? String, !project.isEmpty { entry.projectID = project }
            if let label = row["host_label"] as? String, !label.isEmpty { entry.hostLabel = label }
            if let label = row["workspace_label"] as? String, !label.isEmpty { entry.workspaceLabel = label }
            else if entry.workspaceLabel == nil, let project = row["project"] as? String, !project.isEmpty { entry.workspaceLabel = project }
            if let agent = (row["agent"] as? [String: Any])?["name"] as? String, !agent.isEmpty { entry.agent = agent }
            // A change of state is news: it moves the row to the top.
            if status != previous[threadID]?.status || status == .running || status == .waiting { entry.updatedAt = max(entry.updatedAt, now) }
            entry.status = status
            fresh[threadID] = entry
        }
        // A pinned thread stays even when Zed no longer lists it.
        for (threadID, entry) in previous where fresh[threadID] == nil && Self.isPinned(entry) {
            fresh[threadID] = entry
        }
        entries.removeAll { $0.gatewayID.lowercased() == gatewayID.lowercased() && $0.targetID == targetID }
        entries.append(contentsOf: fresh.values)
        normalize()
    }

    /// Live updates from the connected session between full refreshes.
    func absorb(_ threads: [NativeThread], profile: ConnectionProfile?, targetID: String?, hosts: [WorkspaceHost]) {
        guard let profile, let targetID, !threads.isEmpty else { return }
        let now = Date()
        var changed = false
        for thread in threads {
            let status: SummaryEntry.Status = SummaryEntry.status(of: thread)
            let id: String = [profile.gatewayID.lowercased(), targetID, thread.id].joined(separator: "\n")
            if let index = entries.firstIndex(where: { $0.id == id }) {
                var entry = entries[index]
                if entry.status != status { entry.status = status; entry.updatedAt = now }
                if entry.title != thread.title && !thread.title.isEmpty { entry.title = thread.title }
                if let label = thread.hostLabel { entry.hostLabel = label }
                if let label = thread.workspaceLabel { entry.workspaceLabel = label }
                if entry != entries[index] { entries[index] = entry; changed = true }
            } else {
                var locatedHost: WorkspaceHost?
                var locatedProject: WorkspaceProject?
                for host in hosts where locatedProject == nil {
                    if let project = host.projects.first(where: { project in project.threads.contains(where: { $0.id == thread.id }) }) {
                        locatedHost = host
                        locatedProject = project
                    }
                }
                entries.append(SummaryEntry(gatewayID: profile.gatewayID, connectionName: profile.name, targetID: targetID,
                                            hostID: thread.hostID ?? locatedHost?.id,
                                            hostLabel: thread.hostLabel ?? locatedHost?.label,
                                            projectID: thread.projectID ?? locatedProject?.id,
                                            workspaceLabel: thread.workspaceLabel ?? locatedProject?.name ?? thread.project,
                                            threadID: thread.id, title: thread.title, agent: thread.agentName,
                                            status: status, updatedAt: now))
                changed = true
            }
        }
        if changed { normalize(); save() }
    }

    private func normalize() {
        let now = Date()
        entries.removeAll { now.timeIntervalSince($0.updatedAt) > keepFor && !Self.isPinned($0) }
        entries.sort { $0.updatedAt > $1.updatedAt }
        if entries.count > maxEntries {
            var excess: Int = entries.count - maxEntries
            for index in entries.indices.reversed() where excess > 0 && !Self.isPinned(entries[index]) {
                entries.remove(at: index)
                excess -= 1
            }
        }
    }

    /// Reads the pins `SessionLibrary` stores.
    private static func isPinned(_ entry: SummaryEntry) -> Bool {
        let key: String = SessionLibrary.key(profile: entry.gatewayID, target: entry.targetID, thread: entry.threadID)
        return (UserDefaults.standard.stringArray(forKey: "zedlink.sessionPins") ?? []).contains(key)
    }

    private func save() {
        guard let storageURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storageURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
